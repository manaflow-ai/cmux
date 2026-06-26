import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

/// Orchestrates the "Appshot" feature: a system-wide hotkey captures the
/// frontmost macOS window (screenshot + Accessibility text) and routes it into
/// the active agent surface as context.
///
/// The capture itself runs off the main actor; recency state and delivery stay
/// on the main actor. Pure message formatting and the recency decision live in
/// ``AppshotModel`` so they can be unit-tested without screen capture.
@MainActor
final class AppshotController {
    static let shared = AppshotController()

    private var routingState = AppshotRoutingState()
    private var resignObserver: NSObjectProtocol?
    /// Guards against overlapping captures when the hotkey is held/repeated.
    private var isCapturing = false

    private init() {}

    /// Installs the app-active observer. Idempotent; called once at launch.
    func start() {
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.snapshotInteractiveAgentOnResign()
            }
        }
    }

    /// Snapshots the agent surface the user had focused at the moment cmux lost
    /// focus — the "I was just working with this agent" signal that the
    /// 60-second recency rule keys off of.
    private func snapshotInteractiveAgentOnResign() {
        guard let ref = AppDelegate.shared?.appshotFocusedAgentRef() else { return }
        routingState.lastInteractiveAgent = AppshotAgentRef(
            workspaceId: ref.workspaceId,
            panelId: ref.panelId,
            at: Date()
        )
    }

    /// Entry point invoked by the global hotkey (and reusable by other
    /// entrypoints). Captures off-main, then delivers on the main actor.
    func triggerFromGlobalHotkey() {
        guard !isCapturing else { return }
        isCapturing = true

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let frontApp = NSWorkspace.shared.frontmostApplication
        let pid = frontApp?.processIdentifier ?? 0
        let appName = frontApp?.localizedName
            ?? String(localized: "appshot.unknownApp", defaultValue: "Application")

        Task { @MainActor in
            let capture = await AppshotCapturer.capture(frontPID: pid, appName: appName, scale: scale)
            self.isCapturing = false
            if let capture, capture.promptText() != nil {
                self.deliver(capture)
            } else {
                AppshotPermissions.presentMissingPermissionsPromptIfNeeded()
            }
        }
    }

    private func deliver(_ capture: AppshotCapture) {
        guard let prompt = capture.promptText() else {
            NSSound.beep()
            return
        }
        let now = Date()

        var state = routingState
        // While cmux is frontmost the focused agent is, by definition, the agent
        // the user is interacting with right now.
        if NSApp.isActive, let ref = AppDelegate.shared?.appshotFocusedAgentRef() {
            state.lastInteractiveAgent = AppshotAgentRef(
                workspaceId: ref.workspaceId,
                panelId: ref.panelId,
                at: now
            )
        }

        let lastRouteSurfaceExists = state.lastRoute.map {
            AppDelegate.shared?.appshotSurfaceExists(workspaceId: $0.workspaceId, panelId: $0.panelId) ?? false
        } ?? false
        let lastInteractiveSurfaceExists = state.lastInteractiveAgent.map {
            AppDelegate.shared?.appshotSurfaceExists(workspaceId: $0.workspaceId, panelId: $0.panelId) ?? false
        } ?? false

        let route = AppshotRouteResolver.resolve(
            now: now,
            state: state,
            lastRouteSurfaceExists: lastRouteSurfaceExists,
            lastInteractiveSurfaceExists: lastInteractiveSurfaceExists
        )

        switch route {
        case let .append(workspaceId, panelId):
            if AppDelegate.shared?.sendAppshotText(prompt, workspaceId: workspaceId, panelId: panelId) == true {
                routingState.lastRoute = AppshotAgentRef(workspaceId: workspaceId, panelId: panelId, at: now)
            } else {
                openNewThread(with: prompt, now: now)
            }
        case .newThread:
            openNewThread(with: prompt, now: now)
        }
    }

    private func openNewThread(with prompt: String, now: Date) {
        if let ref = AppDelegate.shared?.openAppshotInNewWorkspace(prompt) {
            routingState.lastRoute = AppshotAgentRef(workspaceId: ref.workspaceId, panelId: ref.panelId, at: now)
        } else {
            NSSound.beep()
        }
    }
}

// MARK: - Permissions

/// Screen Recording + Accessibility permission status for the appshot feature.
struct AppshotPermissions: Equatable {
    let screenRecording: Bool
    let accessibility: Bool

    static func current() -> AppshotPermissions {
        AppshotPermissions(
            screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted()
        )
    }

    /// Shows a single explanatory alert when a capture produced nothing —
    /// almost always because Screen Recording and/or Accessibility access is
    /// missing. The alert's buttons register cmux with TCC and open the
    /// matching System Settings pane so the user can grant access. A richer
    /// re-check/re-grant affordance also lives in Settings → Appshots.
    @MainActor
    static func presentMissingPermissionsPromptIfNeeded() {
        let permissions = current()
        // Both granted but capture still failed (e.g. no frontmost window) —
        // there's nothing to re-grant, so just beep.
        guard !permissions.screenRecording || !permissions.accessibility else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "appshot.permissions.alert.title",
            defaultValue: "Allow cmux to capture appshots"
        )
        alert.informativeText = String(
            localized: "appshot.permissions.alert.body",
            defaultValue: "Sending the frontmost window to your agent needs Screen Recording (for the screenshot) and Accessibility (for the window's text). Grant access in System Settings, then press the shortcut again."
        )
        alert.addButton(withTitle: String(
            localized: "appshot.permissions.alert.openScreenRecording",
            defaultValue: "Open Screen Recording"
        ))
        alert.addButton(withTitle: String(
            localized: "appshot.permissions.alert.openAccessibility",
            defaultValue: "Open Accessibility"
        ))
        alert.addButton(withTitle: String(
            localized: "appshot.permissions.alert.cancel",
            defaultValue: "Cancel"
        ))

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            requestScreenRecording()
            openSettingsPane(SettingsPane.screenRecording)
        case .alertSecondButtonReturn:
            requestAccessibility()
            openSettingsPane(SettingsPane.accessibility)
        default:
            break
        }
    }

    /// Registers cmux in the Screen Recording TCC list (and shows the system
    /// prompt on first use) so it appears with a toggle in System Settings.
    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// Triggers the Accessibility trust prompt so cmux appears in the list.
    static func requestAccessibility() {
        // `kAXTrustedCheckOptionPrompt` imports from C as a non-concurrency-safe
        // global `var`; use its documented, stable string value instead.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    enum SettingsPane {
        static let screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        static let accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    }

    @MainActor
    static func openSettingsPane(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Capture

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

        guard let children = copyElements(element, kAXChildrenAttribute) else { return }
        for child in children {
            collectText(child, into: &pieces, seen: &seen, nodesVisited: &nodesVisited, charCount: &charCount, deadline: deadline)
            if nodesVisited >= maxAccessibilityNodes || charCount >= maxAccessibilityChars || Date() >= deadline { return }
        }
    }

    /// Reads a string attribute capped at `limit` characters. For the value
    /// attribute it first checks the element's character count and, when that
    /// exceeds `limit`, fetches only a leading range via the parameterized AX
    /// text API — so a whole-document `kAXValue` is never copied in full.
    private static func boundedString(_ element: AXUIElement, _ attribute: String, limit: Int) -> String? {
        guard limit > 0 else { return nil }
        if attribute == kAXValueAttribute,
           let count = copyInt(element, kAXNumberOfCharactersAttribute), count > limit {
            if let ranged = copyRangedString(element, location: 0, length: limit) {
                return ranged
            }
        }
        guard let raw = copyString(element, attribute) else { return nil }
        return raw.count > limit ? String(raw.prefix(limit)) : raw
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
