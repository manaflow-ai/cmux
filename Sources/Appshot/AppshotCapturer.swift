import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

/// Captures the frontmost window's image and Accessibility text off the main
/// actor. All inputs that require the main actor (front app pid, display scale)
/// are passed in, so this type touches only thread-safe CG/AX/SCK APIs.
enum AppshotCapturer {
    /// Total Accessibility nodes visited before giving up on a pathological tree.
    private static let maxAccessibilityNodes = 6000
    /// Maximum characters of extracted text retained.
    private static let maxAccessibilityChars = 40000
    /// Wall-clock budget for the whole Accessibility walk, so slow AX IPC (or a
    /// hostile app) can't keep the capture — and `isCapturing` — pending.
    private static let maxAccessibilityDuration: TimeInterval = 2.0
    /// Per-message AX IPC timeout. Each `AXUIElementCopyAttributeValue` is a
    /// synchronous round-trip into the frontmost app; without this a hung app
    /// could block a single call indefinitely (before the walk deadline is even
    /// re-checked) and wedge every later appshot. Set on the app element, which
    /// applies to all of that app's elements.
    private static let maxAccessibilityCallTimeout: Float = 1.0
    /// How many artifact files (PNGs + text dumps) to retain on disk. Appshots
    /// are sensitive window captures triggered by a repeated global hotkey, so
    /// the cache is bounded — older captures are evicted rather than left to
    /// pile up until the OS happens to clear the temp directory. ~12 appshots.
    private static let maxRetainedArtifacts = 24

    static func capture(frontPID: pid_t, appName: String, scale: CGFloat) async -> AppshotCapture? {
        guard frontPID > 0, let window = frontmostWindow(ownerPID: frontPID) else { return nil }

        let screenRecording = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()

        var imagePath: String?
        if screenRecording, let image = await captureWindowImage(windowID: window.windowID, scale: scale) {
            imagePath = writePNG(image)
        }

        // Prefer the Accessibility window title (available without Screen
        // Recording) and fall back to the CGWindowList title.
        var title = window.title
        var textPath: String?
        if accessibility {
            let extracted = extractAccessibilityText(pid: frontPID, axTitle: &title)
            if !extracted.isEmpty {
                textPath = writeText(extracted)
            }
        }

        pruneOldArtifacts()

        return AppshotCapture(
            appName: appName,
            windowTitle: title,
            imagePath: imagePath,
            textPath: textPath,
            screenRecordingDenied: !screenRecording,
            accessibilityDenied: !accessibility
        )
    }

    // MARK: Frontmost window

    private struct FrontmostWindow {
        let windowID: CGWindowID
        let title: String
    }

    /// Finds the frontmost on-screen, normal-layer window owned by `ownerPID`.
    /// `CGWindowListCopyWindowInfo` returns windows front-to-back; window number
    /// and bounds are readable without Screen Recording (only the title is
    /// privacy-gated), so this works for resolving the AX target even when only
    /// Accessibility was granted.
    private static func frontmostWindow(ownerPID: pid_t) -> FrontmostWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in infoList {
            // CFNumber values bridge to NSNumber, not directly to fixed-width
            // ints, so read them through NSNumber to avoid a silent miss.
            guard let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner == ownerPID else { continue }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            if let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
               let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) {
                guard bounds.width > 40, bounds.height > 40 else { continue }
            }
            let title = info[kCGWindowName as String] as? String ?? ""
            return FrontmostWindow(windowID: number, title: title)
        }
        return nil
    }

    // MARK: Image

    private static func captureWindowImage(windowID: CGWindowID, scale: CGFloat) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int((window.frame.width * scale).rounded()))
            configuration.height = max(1, Int((window.frame.height * scale).rounded()))
            configuration.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            return nil
        }
    }

    // MARK: Accessibility text

    private static func extractAccessibilityText(pid: pid_t, axTitle: inout String) -> String {
        // Bound EVERY synchronous AX IPC call in this process for the duration of
        // the walk. A per-element timeout only covers that one element (not the
        // window/child elements actually read), so set it on the system-wide
        // element — which applies process-wide — and restore the default after,
        // so a hung/hostile app can't block a child read and wedge `isCapturing`.
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, maxAccessibilityCallTimeout)
        defer { AXUIElementSetMessagingTimeout(systemWide, 0) }

        let app = AXUIElementCreateApplication(pid)
        let root: AXUIElement
        if let focused = copyElement(app, kAXFocusedWindowAttribute) {
            root = focused
        } else if let windows = copyElements(app, kAXWindowsAttribute), let first = windows.first {
            root = first
        } else {
            root = app
        }

        if axTitle.isEmpty, let windowTitle = copyString(root, kAXTitleAttribute) {
            axTitle = windowTitle
        }

        var pieces: [String] = []
        var seen = Set<String>()
        var nodesVisited = 0
        var charCount = 0
        let deadline = Date().addingTimeInterval(maxAccessibilityDuration)
        collectText(root, into: &pieces, seen: &seen, nodesVisited: &nodesVisited, charCount: &charCount, deadline: deadline)
        return pieces.joined(separator: "\n")
    }

    private static func collectText(
        _ element: AXUIElement,
        into pieces: inout [String],
        seen: inout Set<String>,
        nodesVisited: inout Int,
        charCount: inout Int,
        deadline: Date
    ) {
        guard nodesVisited < maxAccessibilityNodes, charCount < maxAccessibilityChars, Date() < deadline else { return }
        nodesVisited += 1

        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            guard charCount < maxAccessibilityChars else { return }
            // Fetch at most the remaining budget. For a text element's value this
            // uses a ranged AX read so a whole-document value is never materialized
            // in full on this hotkey path.
            guard let bounded = boundedString(element, attribute, limit: maxAccessibilityChars - charCount) else { continue }
            let trimmed = bounded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 1, seen.insert(trimmed).inserted else { continue }
            pieces.append(trimmed)
            charCount += trimmed.count
        }

        // Fetch only as many children as the remaining node budget allows, so a
        // pathological node with thousands of children can't allocate a huge
        // array before the node cap/deadline stops traversal.
        guard let children = copyChildren(element, max: maxAccessibilityNodes - nodesVisited) else { return }
        for child in children {
            collectText(child, into: &pieces, seen: &seen, nodesVisited: &nodesVisited, charCount: &charCount, deadline: deadline)
            if nodesVisited >= maxAccessibilityNodes || charCount >= maxAccessibilityChars || Date() >= deadline { return }
        }
    }

    /// Reads a string attribute capped at `limit` characters. For the value
    /// attribute — which can be a whole document — it reads only a provably
    /// bounded amount: a leading ranged fetch, or a full read solely when the
    /// reported character count proves the value is within budget. A large or
    /// hostile `kAXValue` is never materialized in full on this hotkey path.
    private static func boundedString(_ element: AXUIElement, _ attribute: String, limit: Int) -> String? {
        guard limit > 0 else { return nil }
        if attribute == kAXValueAttribute {
            // The value can be a whole document, so only accept it through a
            // provably bounded read: a leading ranged fetch, or — if ranged is
            // unsupported — a full read only when the reported character count
            // proves it is within budget. Never materialize an unbounded value.
            if let ranged = copyRangedString(element, location: 0, length: limit) {
                return ranged
            }
            guard let count = copyInt(element, kAXNumberOfCharactersAttribute), count <= limit else {
                return nil
            }
        }
        guard let raw = copyString(element, attribute) else { return nil }
        return raw.count > limit ? String(raw.prefix(limit)) : raw
    }

    /// Fetches up to `max` children of `element` via the counted AX array API,
    /// so the children array materialized per node stays bounded.
    private static func copyChildren(_ element: AXUIElement, max: Int) -> [AXUIElement]? {
        guard max > 0 else { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, max, &values) == .success
        else { return nil }
        return values as? [AXUIElement]
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    private static func copyInt(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        return (value as! NSNumber).intValue
    }

    /// Fetches `[location, location+length)` characters from a text element via
    /// `kAXStringForRangeParameterizedAttribute`, avoiding a full-value copy.
    private static func copyRangedString(_ element: AXUIElement, location: Int, length: Int) -> String? {
        var range = CFRange(location: location, length: length)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRange,
            &value
        ) == .success, let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    // MARK: File output

    private static var artifactsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-appshots", isDirectory: true)
    }

    private static func outputURL(extension ext: String) -> URL {
        let directory = artifactsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let short = UUID().uuidString.prefix(8)
        return directory.appendingPathComponent("appshot-\(stamp)-\(short).\(ext)", isDirectory: false)
    }

    /// Evicts the oldest artifacts so the on-disk cache of (sensitive) window
    /// captures stays bounded across repeated hotkey use. Keeps the most-recent
    /// ``maxRetainedArtifacts`` files by modification date.
    private static func pruneOldArtifacts() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: artifactsDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ), entries.count > maxRetainedArtifacts else { return }

        let modified: (URL) -> Date = { url in
            (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
        }
        let oldestFirst = entries.sorted { modified($0) < modified($1) }
        for url in oldestFirst.prefix(entries.count - maxRetainedArtifacts) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func writePNG(_ image: CGImage) -> String? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let url = outputURL(extension: "png")
        do {
            try data.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }

    private static func writeText(_ text: String) -> String? {
        let url = outputURL(extension: "txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            return nil
        }
    }
}
