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
    /// Maximum characters accepted from a direct AX control metadata string.
    private static let maxDirectAccessibilityStringChars = 512
    /// Maximum direct AX string reads per capture, after which ranged reads only.
    private static let maxDirectAccessibilityStringReads = 256
    /// Maximum characters expected in an AX role string.
    private static let maxAccessibilityRoleChars = 64
    /// Maximum width or height requested from ScreenCaptureKit for one appshot.
    private static let maxScreenshotDimension = 4096
    /// Maximum total pixels requested from ScreenCaptureKit for one appshot.
    private static let maxScreenshotPixels = 12_000_000
    /// Wall-clock budget for the whole Accessibility walk, so slow AX IPC (or a
    /// hostile app) can't keep the capture — and `isCapturing` — pending.
    private static let maxAccessibilityDuration: TimeInterval = 2.0
    /// Per-message AX IPC timeout. Each `AXUIElementCopyAttributeValue` is a
    /// synchronous round-trip into the frontmost app; without this a hung app
    /// could block a single call indefinitely (before the walk deadline is even
    /// re-checked) and wedge every later appshot. Set process-wide via the
    /// system-wide AX element so every element's reads are bounded.
    private static let maxAccessibilityCallTimeout: Float = 1.0
    /// Windows fetched and frame-matched against the captured window. Each window
    /// costs two AX reads (position + size), and a hostile app can report
    /// arbitrarily many windows, so the count is bounded at the IPC fetch itself
    /// (not just the later scan) — realistic apps have far fewer. Past this cap
    /// (or the walk deadline) the capture falls back to the focused window rather
    /// than scan unboundedly.
    private static let maxWindowsToScan = 64
    /// How many artifact files (PNGs + text dumps) to retain on disk. Appshots
    /// are sensitive window captures triggered by a repeated global hotkey, so
    /// the cache is bounded — older captures are evicted rather than left to
    /// pile up until the OS happens to clear the temp directory. ~12 appshots.
    private static let maxRetainedArtifacts = 24
    /// Roles whose ordinary AX string attributes are short control metadata.
    private static let directStringRoles: Set<String> = [
        "AXButton", "AXCell", "AXCheckBox", "AXComboBox", "AXGroup", "AXHeading",
        "AXImage", "AXLink", "AXMenuButton", "AXMenuItem", "AXPopUpButton", "AXRadioButton",
        "AXRow", "AXSlider", "AXStaticText", "AXTextField", "AXValueIndicator",
    ]
    /// AX string attributes that are useful as small control metadata.
    private static let directStringAttributes: Set<String> = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
    static func capture(frontPID: pid_t, appName: String, scale: CGFloat) async -> AppshotCapture? {
        guard frontPID > 0, let window = frontmostWindow(ownerPID: frontPID) else { return nil }

        let screenRecording = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()

        // ScreenCaptureKit capture is genuinely async (suspends, doesn't block).
        let image: CGImage? = screenRecording
            ? await captureWindowImage(windowID: window.windowID, scale: scale)
            : nil

        // The Accessibility walk is synchronous IPC — up to thousands of
        // round-trips — and PNG encoding plus the file writes are CPU/disk work,
        // so run all of it off the bounded cooperative thread pool rather than
        // blocking a pool thread. The window title uses the CGWindowList title
        // captured above; AX title/description strings are accepted only as
        // small control metadata, while document-like text stays on ranged reads.
        // `image` is an immutable, Sendable `CGImage?`, so it crosses into the
        // queue closure like the other Sendable value captures.
        return await withCheckedContinuation { (continuation: CheckedContinuation<AppshotCapture?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let imagePath = image.flatMap { writePNG($0) }
                let title = window.title
                var textPath: String?
                if accessibility {
                    let extracted = extractAccessibilityText(pid: frontPID, targetBounds: window.bounds)
                    if !extracted.isEmpty {
                        textPath = writeText(extracted)
                    }
                }
                pruneOldArtifacts()
                continuation.resume(returning: AppshotCapture(
                    appName: appName,
                    windowTitle: title,
                    imagePath: imagePath,
                    textPath: textPath,
                    screenRecordingDenied: !screenRecording,
                    accessibilityDenied: !accessibility
                ))
            }
        }
    }

    // MARK: Frontmost window

    /// Finds the frontmost on-screen, normal-layer window owned by `ownerPID`.
    /// `CGWindowListCopyWindowInfo` returns windows front-to-back; window number
    /// and bounds are readable without Screen Recording (only the title is
    /// privacy-gated), so this works for resolving the AX target even when only
    /// Accessibility was granted.
    private static func frontmostWindow(ownerPID: pid_t) -> AppshotFrontmostWindow? {
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
            var windowBounds: CGRect?
            if let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
               let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) {
                guard bounds.width > 40, bounds.height > 40 else { continue }
                windowBounds = bounds
            }
            let title = info[kCGWindowName as String] as? String ?? ""
            return AppshotFrontmostWindow(windowID: number, title: title, bounds: windowBounds)
        }
        return nil
    }

    // MARK: Image

    private static func captureWindowImage(windowID: CGWindowID, scale: CGFloat) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            guard let dimensions = boundedScreenshotDimensions(frame: window.frame, scale: scale) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = dimensions.width
            configuration.height = dimensions.height
            configuration.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            return nil
        }
    }

    private static func boundedScreenshotDimensions(frame: CGRect, scale: CGFloat) -> (width: Int, height: Int)? {
        let rawWidth = Double(frame.width * scale)
        let rawHeight = Double(frame.height * scale)
        guard rawWidth.isFinite, rawHeight.isFinite, rawWidth > 0, rawHeight > 0 else { return nil }

        let maxDimension = Double(maxScreenshotDimension)
        let maxPixels = Double(maxScreenshotPixels)
        let pixelCount = rawWidth * rawHeight
        guard pixelCount.isFinite, pixelCount > 0 else { return nil }

        var ratio = min(1, maxDimension / rawWidth, maxDimension / rawHeight)
        if pixelCount * ratio * ratio > maxPixels {
            ratio = min(ratio, sqrt(maxPixels / pixelCount))
        }

        return (
            width: max(1, Int((rawWidth * ratio).rounded(.down))),
            height: max(1, Int((rawHeight * ratio).rounded(.down)))
        )
    }

    // MARK: Accessibility text

    private static func extractAccessibilityText(pid: pid_t, targetBounds: CGRect?) -> String {
        let app = AXUIElementCreateApplication(pid)
        // Bound every synchronous AX IPC call to the target app for the duration
        // of the walk. Setting the timeout on the system-wide element does not
        // reliably bound requests made through the app/window/child elements.
        AXUIElementSetMessagingTimeout(app, maxAccessibilityCallTimeout)
        defer { AXUIElementSetMessagingTimeout(app, 0) }

        // One wall-clock budget for the ENTIRE capture: window resolution and
        // the node walk share it, so a slow or hostile app (many windows and/or
        // slow IPC) can't keep the capture — and
        // `isCapturing` — pending well past the advertised budget. Each AX call
        // is separately bounded by the app messaging timeout above, so
        // the worst-case overshoot is one in-flight call past the deadline.
        let deadline = Date().addingTimeInterval(maxAccessibilityDuration)
        guard let root = resolveTargetWindow(app: app, matching: targetBounds, deadline: deadline) else { return "" }

        var pieces: [String] = []
        var seen = Set<String>()
        var nodesVisited = 0
        var charCount = 0
        var directStringReads = 0
        collectText(
            root,
            into: &pieces,
            seen: &seen,
            nodesVisited: &nodesVisited,
            charCount: &charCount,
            directStringReads: &directStringReads,
            deadline: deadline
        )
        return pieces.joined(separator: "\n")
    }

    // MARK: Window binding

    /// Selects the AX window element for the window the screenshot captured, so
    /// the extracted text and the image describe the *same* window. The image is
    /// pinned to a `CGWindowID` resolved before the async ScreenCaptureKit call,
    /// so reading the app's focused window at AX time can drift to a different
    /// window if focus moves mid-capture (multi-window apps). Match by frame
    /// instead: CGWindowList bounds and AX `kAXPosition`/`kAXSize` are both in
    /// top-left-origin global screen points.
    ///
    /// The frame match is used only when it is *unique*. Two windows with
    /// identical frames (perfectly stacked or duplicate windows) can't be told
    /// apart by frame alone, and AX window order need not match the captured
    /// front-to-back order — so a non-unique match must not guess a window.
    ///
    /// Falls back to the focused-window heuristic when the frame match is absent
    /// or ambiguous (bounds unavailable, window resized/closed mid-capture, a
    /// coordinate-space mismatch, or identical frames). The focused window is the
    /// most likely frontmost/captured window. If the shared deadline expires, or
    /// the focused window cannot be read, text capture is omitted rather than
    /// walking the whole app Accessibility tree.
    private static func resolveTargetWindow(app: AXUIElement, matching targetBounds: CGRect?, deadline: Date) -> AXUIElement? {
        // Cap the window array at the IPC boundary (see ``copyElements``): a
        // buggy or hostile frontmost app can report arbitrarily many windows, so
        // the count bound must apply before the array is materialized, not after.
        let windows = copyElements(app, kAXWindowsAttribute, max: maxWindowsToScan)
        if let targetBounds, let windows {
            // The frame scan is additionally bounded by the shared deadline: each
            // window costs two AX reads, so slow IPC can't exhaust the capture
            // budget before the walk even starts. `frames` stays index-aligned
            // with `windows`, so a match still selects the right element; a
            // partial scan simply falls back to the focused window.
            var frames: [CGRect?] = []
            frames.reserveCapacity(windows.count)
            for window in windows {
                guard Date() < deadline else { break }
                frames.append(axWindowFrame(window, deadline: deadline))
            }
            if let index = uniqueIndexOfFrame(matching: targetBounds, in: frames) {
                return windows[index]
            }
        }
        guard Date() < deadline else { return nil }
        return copyElement(app, kAXFocusedWindowAttribute)
    }

    /// Index of the window whose frame *uniquely* matches `target` within
    /// `tolerance` points on all four edges, or `nil` when zero — or more than
    /// one — frame matches. A non-unique match (identical or overlapping frames)
    /// can't be disambiguated by frame alone, so the caller falls back to the
    /// focused-window heuristic rather than attach the wrong window's text. Pure
    /// and total so the window-binding selection can be unit-tested without live
    /// AX state.
    static func uniqueIndexOfFrame(matching target: CGRect, in frames: [CGRect?], tolerance: CGFloat = 2) -> Int? {
        var match: Int?
        for (index, frame) in frames.enumerated() {
            guard let frame,
                  abs(frame.origin.x - target.origin.x) <= tolerance,
                  abs(frame.origin.y - target.origin.y) <= tolerance,
                  abs(frame.size.width - target.size.width) <= tolerance,
                  abs(frame.size.height - target.size.height) <= tolerance
            else { continue }
            if match != nil { return nil }  // ambiguous: two windows share this frame
            match = index
        }
        return match
    }

    /// Reads an AX window's frame (top-left-origin global screen points) from its
    /// `kAXPosition`/`kAXSize` attributes, or `nil` when either is missing.
    private static func axWindowFrame(_ window: AXUIElement, deadline: Date) -> CGRect? {
        guard Date() < deadline,
              let positionValue = copyAXValue(window, kAXPositionAttribute),
              Date() < deadline,
              let sizeValue = copyAXValue(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func copyAXValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private static func collectText(
        _ element: AXUIElement,
        into pieces: inout [String],
        seen: inout Set<String>,
        nodesVisited: inout Int,
        charCount: inout Int,
        directStringReads: inout Int,
        deadline: Date
    ) {
        guard nodesVisited < maxAccessibilityNodes, charCount < maxAccessibilityChars, Date() < deadline else { return }
        nodesVisited += 1

        let allowsDirectStringFallback = hasDirectStringRole(element, directStringReads: &directStringReads)
        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            // Re-check the deadline before each AX read, not just once per node,
            // so a node's several IPC calls can't overshoot the budget together.
            guard charCount < maxAccessibilityChars, Date() < deadline else { return }
            // Prefer ranged value reads. Controls and labels that expose visible
            // text only through AXTitle/AXDescription/plain AXValue get a small,
            // role-gated direct-read fallback; oversized strings are rejected
            // before bridging to Swift, and the capture has a total direct-read
            // budget so a large tree cannot issue thousands of direct string IPCs.
            guard let bounded = boundedString(
                element,
                attribute,
                limit: maxAccessibilityChars - charCount,
                allowsDirectFallback: allowsDirectStringFallback,
                directStringReads: &directStringReads
            ) else { continue }
            let trimmed = bounded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 1, seen.insert(trimmed).inserted else { continue }
            pieces.append(trimmed)
            charCount += trimmed.count
        }

        // Fetch only as many children as the remaining node budget allows, so a
        // pathological node with thousands of children can't allocate a huge
        // array before the node cap/deadline stops traversal.
        guard Date() < deadline,
              let children = copyChildren(element, max: maxAccessibilityNodes - nodesVisited) else { return }
        for child in children {
            collectText(
                child,
                into: &pieces,
                seen: &seen,
                nodesVisited: &nodesVisited,
                charCount: &charCount,
                directStringReads: &directStringReads,
                deadline: deadline
            )
            if nodesVisited >= maxAccessibilityNodes || charCount >= maxAccessibilityChars || Date() >= deadline { return }
        }
    }

    /// Reads a string attribute through a ranged value read, with a narrow
    /// fallback for small role-gated control metadata.
    private static func boundedString(
        _ element: AXUIElement,
        _ attribute: String,
        limit: Int,
        allowsDirectFallback: Bool,
        directStringReads: inout Int
    ) -> String? {
        guard limit > 0 else { return nil }
        if attribute == kAXValueAttribute,
           let ranged = copyRangedString(element, location: 0, length: limit) {
            // A provider that ignores the requested length could return more than
            // `limit`; clamp so the bounded-read guarantee holds after bridging.
            return ranged.count > limit ? String(ranged.prefix(limit)) : ranged
        }
        guard allowsDirectFallback,
              directStringAttributes.contains(attribute),
              claimDirectStringRead(&directStringReads) else { return nil }
        return copySmallDirectString(
            element,
            attribute,
            limit: min(limit, maxDirectAccessibilityStringChars)
        )
    }

    private static func hasDirectStringRole(_ element: AXUIElement, directStringReads: inout Int) -> Bool {
        guard claimDirectStringRead(&directStringReads),
              let role = copySmallDirectString(element, kAXRoleAttribute, limit: maxAccessibilityRoleChars)
        else { return false }
        return directStringRoles.contains(role)
    }

    private static func claimDirectStringRead(_ directStringReads: inout Int) -> Bool {
        guard directStringReads < maxDirectAccessibilityStringReads else { return false }
        directStringReads += 1
        return true
    }

    /// Copies small AX strings only for role-gated control metadata. Oversized
    /// values are dropped before bridging to Swift instead of being truncated
    /// after a large Swift allocation.
    private static func copySmallDirectString(_ element: AXUIElement, _ attribute: String, limit: Int) -> String? {
        guard limit > 0 else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        let cfString = value as! CFString
        guard CFStringGetLength(cfString) <= limit else { return nil }
        return cfString as String
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

    /// Fetches up to `max` elements of `attribute` via the counted AX array API,
    /// so a buggy or hostile AX provider can't force cmux to materialize an
    /// enormous array at the IPC boundary before any cap applies (mirrors
    /// ``copyChildren``).
    private static func copyElements(_ element: AXUIElement, _ attribute: String, max: Int) -> [AXUIElement]? {
        guard max > 0 else { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, attribute as CFString, 0, max, &values) == .success
        else { return nil }
        return values as? [AXUIElement]
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
