import AppKit
import ApplicationServices
import SwiftUI
import CmuxSettings

struct AgentSessionPanelView: View {
    @AppStorage(SessionContentWidthSettings.maxWidthKey)
    private var storedSessionContentMaximumWidth = SessionContentWidthSettings.noMaximumWidth
    @AppStorage(SessionContentWidthSettings.alignmentKey)
    private var storedSessionContentAlignment = SessionContentAlignment.center.rawValue
    let panel: AgentSessionPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        Group {
            if panel.rendererKind == .claudeDesktop {
                ClaudeDesktopAgentSessionSurface(
                    panelID: panel.id,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    backgroundColor: appearance.contentBackgroundColor
                )
                .id(panel.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(Double(portalPriority))
            } else if isVisibleInUI {
                AgentSessionWebRenderer(
                    panel: panel,
                    isFocused: isFocused,
                    backgroundColor: appearance.contentBackgroundColor,
                    theme: AgentSessionWebTheme.resolve(appearance: appearance),
                    sessionContentWidthPresentation: sessionContentWidthPresentation,
                    onRequestPanelFocus: onRequestPanelFocus
                )
                .id(panel.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(Double(portalPriority))
            } else {
                Color.clear
            }
        }
        .background(Color(nsColor: appearance.contentBackgroundColor))
    }

    private var sessionContentWidthPresentation: SessionContentWidthPresentation {
        SessionContentWidthPresentation(
            storedMaximumWidth: storedSessionContentMaximumWidth,
            storedAlignment: storedSessionContentAlignment
        )
    }
}

/// Phase-0 RFC #13984 renderer. This deliberately lives beside the existing
/// agent-session view so the disposable spike does not add Xcode target wiring.
private struct ClaudeDesktopAgentSessionSurface: NSViewRepresentable {
    let panelID: UUID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let backgroundColor: NSColor

    func makeNSView(context: Context) -> ClaudeDesktopPaneHostView {
        ClaudeDesktopPaneHostView(panelID: panelID)
    }

    func updateNSView(_ nsView: ClaudeDesktopPaneHostView, context: Context) {
        nsView.update(
            isFocused: isFocused,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor
        )
    }

    static func dismantleNSView(_ nsView: ClaudeDesktopPaneHostView, coordinator: ()) {
        nsView.invalidate()
    }
}

@MainActor
private final class ClaudeDesktopPaneHostView: NSView {
    private let externalSession: ClaudeDesktopWindowSession
    private var isFocused = false
    private var isVisibleInUI = false
    private weak var observedHostWindow: NSWindow?

    init(panelID: UUID) {
        self.externalSession = ClaudeDesktopWindowSession(panelID: panelID)
        super.init(frame: .zero)
        wantsLayer = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cmuxApplicationBecameActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installHostWindowObservers()
        externalSession.startIfNeeded()
        syncPresentation(raiseExternalWindow: isFocused)
    }

    override func layout() {
        super.layout()
        syncPresentation(raiseExternalWindow: false)
    }

    func update(
        isFocused: Bool,
        isVisibleInUI: Bool,
        backgroundColor: NSColor
    ) {
        let becameFocused = isFocused && !self.isFocused
        let becameVisible = isVisibleInUI && !self.isVisibleInUI
        self.isFocused = isFocused
        self.isVisibleInUI = isVisibleInUI
        layer?.backgroundColor = backgroundColor.cgColor
        externalSession.startIfNeeded()
        syncPresentation(raiseExternalWindow: becameFocused || becameVisible)
    }

    func invalidate() {
        removeHostWindowObservers()
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        externalSession.invalidate()
    }

    private func installHostWindowObservers() {
        guard observedHostWindow !== window else { return }
        removeHostWindowObservers()
        guard let window else { return }
        observedHostWindow = window
        let center = NotificationCenter.default
        for name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didBecomeKeyNotification
        ] {
            center.addObserver(
                self,
                selector: #selector(hostWindowChanged(_:)),
                name: name,
                object: window
            )
        }
    }

    private func removeHostWindowObservers() {
        guard let observedHostWindow else { return }
        let center = NotificationCenter.default
        for name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didBecomeKeyNotification
        ] {
            center.removeObserver(self, name: name, object: observedHostWindow)
        }
        self.observedHostWindow = nil
    }

    @objc private func hostWindowChanged(_ notification: Notification) {
        let shouldRaise = notification.name == NSWindow.didBecomeKeyNotification
            || notification.name == NSWindow.didDeminiaturizeNotification
        syncPresentation(raiseExternalWindow: shouldRaise)
    }

    @objc private func cmuxApplicationBecameActive(_ notification: Notification) {
        _ = notification
        syncPresentation(raiseExternalWindow: true)
    }

    private func syncPresentation(raiseExternalWindow: Bool) {
        let hostWindowVisible = window?.isVisible == true
            && window?.isMiniaturized == false
        let shouldShow = isVisibleInUI && hostWindowVisible
        externalSession.updatePresentation(
            targetFrame: shouldShow ? accessibilityScreenFrame() : nil,
            isVisible: shouldShow,
            isFocused: isFocused,
            raiseWindow: raiseExternalWindow
        )
    }

    private func accessibilityScreenFrame() -> CGRect? {
        guard let window else { return nil }
        let windowRect = convert(bounds, to: nil)
        let appKitScreenRect = window.convertToScreen(windowRect)
        guard appKitScreenRect.width >= 1, appKitScreenRect.height >= 1 else {
            return nil
        }

        // AppKit's global screen coordinates grow upward from the primary
        // display. Accessibility window coordinates grow downward from its top.
        let primaryScreenTop = NSScreen.screens.first?.frame.maxY ?? appKitScreenRect.maxY
        return CGRect(
            x: appKitScreenRect.minX,
            y: primaryScreenTop - appKitScreenRect.maxY,
            width: appKitScreenRect.width,
            height: appKitScreenRect.height
        )
    }
}

@MainActor
private final class ClaudeDesktopWindowSession {
    private let panelID: UUID
    private var launchTask: Task<Void, Never>?
    private var hasAttemptedLaunch = false
    private var isInvalidated = false
    private var runningApplication: NSRunningApplication?
    private var applicationElement: AXUIElement?
    private var externalWindow: AXUIElement?
    private var accessibilityObserver: AXObserver?
    private var accessibilityPromptRequested = false
    private var targetFrame: CGRect?
    private var shouldBeVisible = false
    private var shouldBeFocused = false

    init(panelID: UUID) {
        self.panelID = panelID
    }

    func startIfNeeded() {
        guard !isInvalidated,
              !hasAttemptedLaunch,
              launchTask == nil,
              runningApplication == nil else {
            if runningApplication != nil {
                ensureAccessibilityBinding()
            }
            return
        }
        hasAttemptedLaunch = true

        guard let applicationURL = Self.claudeApplicationURL() else {
#if DEBUG
            cmuxDebugLog("agentSession.claudeDesktop.appMissing panel=\(panelID.uuidString)")
#endif
            return
        }

        let profileURL = Self.profileDirectoryURL(panelID: panelID)
        do {
            try FileManager.default.createDirectory(
                at: profileURL,
                withIntermediateDirectories: true
            )
        } catch {
#if DEBUG
            cmuxDebugLog(
                "agentSession.claudeDesktop.profileCreateFailed panel=\(panelID.uuidString) "
                    + "error=\(error.localizedDescription)"
            )
#endif
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.hides = true
        configuration.addsToRecentItems = false
        configuration.arguments = ["--user-data-dir=\(profileURL.path)"]

        launchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.launchTask = nil }
            do {
                let application = try await NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: configuration
                )
                guard !Task.isCancelled, !self.isInvalidated else {
                    application.terminate()
                    return
                }
                self.runningApplication = application
                self.ensureAccessibilityBinding()
                self.applyPresentation(
                    activateIfFocused: self.shouldBeFocused,
                    raiseWindow: true
                )
            } catch {
#if DEBUG
                cmuxDebugLog(
                    "agentSession.claudeDesktop.launchFailed panel=\(self.panelID.uuidString) "
                        + "error=\(error.localizedDescription)"
                )
#endif
            }
        }
    }

    func updatePresentation(
        targetFrame: CGRect?,
        isVisible: Bool,
        isFocused: Bool,
        raiseWindow: Bool
    ) {
        guard !isInvalidated else { return }
        let becameFocused = isFocused && !shouldBeFocused
        let becameVisible = isVisible && !shouldBeVisible
        self.targetFrame = targetFrame
        shouldBeVisible = isVisible
        shouldBeFocused = isFocused

        if runningApplication == nil {
            startIfNeeded()
            return
        }
        ensureAccessibilityBinding()
        applyPresentation(
            activateIfFocused: becameFocused,
            raiseWindow: raiseWindow || becameVisible
        )
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        launchTask?.cancel()
        launchTask = nil
        removeAccessibilityObserver()
        externalWindow = nil
        applicationElement = nil

        if let runningApplication, !runningApplication.isTerminated {
            runningApplication.terminate()
        }
        self.runningApplication = nil
    }

    private func ensureAccessibilityBinding() {
        guard let runningApplication, !runningApplication.isTerminated else { return }

        let shouldPrompt = !accessibilityPromptRequested
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: shouldPrompt
        ] as CFDictionary
        accessibilityPromptRequested = true
        guard AXIsProcessTrustedWithOptions(options) else { return }

        if applicationElement == nil {
            applicationElement = AXUIElementCreateApplication(
                runningApplication.processIdentifier
            )
        }
        installAccessibilityObserverIfNeeded()
        refreshExternalWindow()
    }

    private func installAccessibilityObserverIfNeeded() {
        guard accessibilityObserver == nil,
              let applicationElement,
              let runningApplication else {
            return
        }

        var observer: AXObserver?
        let createResult = AXObserverCreate(
            runningApplication.processIdentifier,
            Self.accessibilityObserverCallback,
            &observer
        )
        guard createResult == .success, let observer else {
#if DEBUG
            cmuxDebugLog(
                "agentSession.claudeDesktop.axObserverCreateFailed "
                    + "panel=\(panelID.uuidString) code=\(createResult.rawValue)"
            )
#endif
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notificationResult = AXObserverAddNotification(
            observer,
            applicationElement,
            kAXWindowCreatedNotification as CFString,
            refcon
        )
        guard notificationResult == .success
                || notificationResult == .notificationAlreadyRegistered else {
#if DEBUG
            cmuxDebugLog(
                "agentSession.claudeDesktop.axObserverAddFailed "
                    + "panel=\(panelID.uuidString) code=\(notificationResult.rawValue)"
            )
#endif
            return
        }

        accessibilityObserver = observer
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }

    private func removeAccessibilityObserver() {
        guard let accessibilityObserver else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(accessibilityObserver),
            .commonModes
        )
        self.accessibilityObserver = nil
    }

    private func refreshExternalWindow() {
        guard let applicationElement else { return }

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &value
        )
        guard result == .success,
              let windows = value as? [AXUIElement],
              let firstWindow = windows.first else {
            return
        }

        if externalWindow == nil {
            externalWindow = firstWindow
            applyPresentation(
                activateIfFocused: shouldBeFocused,
                raiseWindow: true
            )
        }
    }

    private func applyPresentation(
        activateIfFocused: Bool,
        raiseWindow: Bool
    ) {
        guard let runningApplication, !runningApplication.isTerminated else { return }

        guard shouldBeVisible else {
            if !runningApplication.isHidden {
                _ = runningApplication.hide()
            }
            return
        }

        guard let targetFrame else { return }
        if externalWindow == nil {
            refreshExternalWindow()
        }
        guard let externalWindow else { return }

        if !setExternalWindowFrame(targetFrame, window: externalWindow) {
            self.externalWindow = nil
            refreshExternalWindow()
            guard let replacementWindow = self.externalWindow else { return }
            _ = setExternalWindowFrame(targetFrame, window: replacementWindow)
        }

        _ = AXUIElementSetAttributeValue(
            self.externalWindow ?? externalWindow,
            kAXMinimizedAttribute as CFString,
            kCFBooleanFalse
        )
        if runningApplication.isHidden {
            _ = runningApplication.unhide()
        }
        if raiseWindow, let window = self.externalWindow {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        if activateIfFocused && shouldBeFocused {
            _ = runningApplication.activate(options: [.activateAllWindows])
            if let window = self.externalWindow {
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }
    }

    private func setExternalWindowFrame(_ frame: CGRect, window: AXUIElement) -> Bool {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return false
        }

        let positionResult = AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            positionValue
        )
        let sizeResult = AXUIElementSetAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            sizeValue
        )
        return positionResult == .success && sizeResult == .success
    }

    nonisolated private static let accessibilityObserverCallback: AXObserverCallback = {
        _, _, _, refcon in
        guard let refcon else { return }
        let session = Unmanaged<ClaudeDesktopWindowSession>
            .fromOpaque(refcon)
            .takeUnretainedValue()
        Task { @MainActor in
            session.refreshExternalWindow()
        }
    }

    private static func claudeApplicationURL() -> URL? {
        let fileManager = FileManager.default
        if let overridePath = ProcessInfo.processInfo.environment[
            "CMUX_CLAUDE_DESKTOP_APP_PATH"
        ] {
            let overrideURL = URL(fileURLWithPath: overridePath)
            if fileManager.fileExists(atPath: overrideURL.path) {
                return overrideURL
            }
        }

        if let installedURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.anthropic.claudefordesktop"
        ) {
            return installedURL
        }

        let candidates = [
            URL(fileURLWithPath: "/Applications/Claude.app"),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Claude.app", isDirectory: true)
        ]
        return candidates.first {
            fileManager.fileExists(atPath: $0.path)
        }
    }

    private static func profileDirectoryURL(panelID: UUID) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/cmux", isDirectory: true)
            .appendingPathComponent("external-apps/claude", isDirectory: true)
            .appendingPathComponent(panelID.uuidString.lowercased(), isDirectory: true)
    }
}
