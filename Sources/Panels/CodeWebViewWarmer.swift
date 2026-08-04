import AppKit
import Foundation
import WebKit

/// Keeps a small pool of fully rendered live Code clients. A panel adopts the
/// same connected web view, so the first visible frame is the real client and
/// no placeholder UI or runtime handoff is involved.
@MainActor
final class CodeWebViewWarmer: NSObject {
    static let shared = CodeWebViewWarmer()

    private struct Host {
        let containerView: NSView
        let window: NSWindow
        let ownsWindow: Bool
        let preservesRenderingOnClaim: Bool
        let presentationFrame: NSRect?
    }

    private enum LoadState {
        case loading
        case finished
    }

    private struct Entry {
        let webView: CmuxWebView
        let profileID: UUID
        let websiteDataStore: WKWebsiteDataStore
        let host: Host
        let startedAt: TimeInterval
        let workingDirectory: String?
        var loadState: LoadState
    }

    private struct ClaimPresentationHint {
        let window: NSWindow
        let frame: NSRect?
        let expiresAt: TimeInterval
    }

    private var entries: [Entry] = []
    private let capacity: Int
    private let makeWebView: @MainActor (UUID, WKWebsiteDataStore) -> CmuxWebView
    private let startLoad: @MainActor (CmuxWebView, URLRequest) -> Void
    private let targetWindowProvider: @MainActor () -> NSWindow?
    private let presentationFrameProvider: @MainActor (NSWindow) -> NSRect?
    private weak var lastTargetWindow: NSWindow?
    private var nextClaimPresentationHint: ClaimPresentationHint?
    private var keyWindowObserver: NSObjectProtocol?
    private var themeObservers: [NSObjectProtocol] = []

    init(
        capacity: Int = 4,
        makeWebView: @escaping @MainActor (UUID, WKWebsiteDataStore) -> CmuxWebView = {
            profileID,
            websiteDataStore in
            BrowserPanel.makeWebView(
                profileID: profileID,
                websiteDataStore: websiteDataStore
            )
        },
        startLoad: @escaping @MainActor (CmuxWebView, URLRequest) -> Void = {
            webView,
            request in
            webView.applyBrowserUserAgentPolicy(for: request.url)
            webView.load(request)
        },
        targetWindowProvider: @escaping @MainActor () -> NSWindow? = {
            CodeWebViewWarmer.preferredTargetWindow()
        },
        presentationFrameProvider: @escaping @MainActor (NSWindow) -> NSRect? = {
            CodeWebViewWarmer.focusedSurfaceFrame(in: $0)
        },
        observeKeyWindows: Bool = true
    ) {
        self.capacity = max(1, capacity)
        self.makeWebView = makeWebView
        self.startLoad = startLoad
        self.targetWindowProvider = targetWindowProvider
        self.presentationFrameProvider = presentationFrameProvider
        super.init()
        if observeKeyWindows {
            keyWindowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? CmuxMainWindow else { return }
                Task { @MainActor [weak self] in
                    self?.prewarmDefaultProfile(targetWindow: window)
                }
            }
            themeObservers = [
                Notification.Name.ghosttyConfigDidReload,
                Notification.Name.ghosttyDefaultBackgroundDidChange,
            ].map { name in
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshTheme()
                    }
                }
            }
        }
    }

    deinit {
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
        }
        for observer in themeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var entryCount: Int { entries.count }
    var readyCount: Int {
        entries.reduce(into: 0) { count, entry in
            if case .finished = entry.loadState { count += 1 }
        }
    }

    func prewarmDefaultProfile(targetWindow: NSWindow? = nil) {
        let profileID = BrowserPanel.resolvedProfileID(requested: nil)
        prewarm(
            profileID: profileID,
            websiteDataStore: BrowserProfileStore.shared.websiteDataStore(for: profileID),
            workingDirectory: AppDelegate.shared?.tabManager?.selectedWorkspace?.currentDirectory,
            targetWindow: targetWindow ?? targetWindowProvider()
        )
    }

    func prewarm(
        profileID: UUID,
        websiteDataStore: WKWebsiteDataStore,
        workingDirectory: String? = nil,
        targetWindow: NSWindow? = nil
    ) {
        guard let launcherURL = CodeStaticURLSchemeHandler.launcherURL else { return }
        let resolvedTargetWindow = targetWindow
            ?? targetWindowProvider()
            ?? rememberedTargetWindow()
        if let resolvedTargetWindow {
            lastTargetWindow = resolvedTargetWindow
        }
        if entries.contains(where: {
            $0.profileID != profileID || $0.websiteDataStore !== websiteDataStore
        }) {
            discard(reason: "profile-changed")
        }
        if let resolvedTargetWindow,
           entries.contains(where: { $0.host.window !== resolvedTargetWindow }) {
            discard(reason: "window-changed")
        }
        guard entries.count < capacity,
              !entries.contains(where: {
                  if case .loading = $0.loadState { return true }
                  return false
              }) else {
            return
        }

        // Fill serially. Each entry runs the actual client and connects to the
        // shared sidecar before it can be claimed.
        let webView = makeWebView(profileID, websiteDataStore)
        Self.applyTransparentBackground(to: webView)
        // WKWebView's remote accessibility subtree can bypass a hidden parent.
        // Suppress its children until this exact rendered view becomes visible.
        webView.isCodePrewarmAccessibilitySuppressed = true
        _ = CodeSurfaceMessageHandler.install(
            on: webView,
            surfaceID: UUID(),
            workingDirectory: workingDirectory
        )
        webView.onCodeSurfaceReady = { [weak self, weak webView] in
            guard let self, let webView else { return }
            self.markReady(webView)
        }
        webView.onCodeSurfaceUnready = { [weak self, weak webView] in
            guard let self, let webView else { return }
            self.markUnready(webView)
        }
        webView.onCodeSurfaceFailed = { [weak self, weak webView] in
            guard let self, let webView else { return }
            self.discard(webView: webView, reason: "runtime-failed")
        }
        webView.navigationDelegate = self
        let presentationFrame = resolvedTargetWindow.flatMap(presentationFrameProvider)
        let host = Self.makeHost(
            for: webView,
            targetWindow: resolvedTargetWindow,
            presentationFrame: presentationFrame
        )
        entries.append(
            Entry(
                webView: webView,
                profileID: profileID,
                websiteDataStore: websiteDataStore,
                host: host,
                startedAt: ProcessInfo.processInfo.systemUptime,
                workingDirectory: workingDirectory,
                loadState: .loading
            )
        )
        startLoad(webView, URLRequest(url: launcherURL))
#if DEBUG
        cmuxDebugLog(
            "code.warmer.start profile=\(profileID.uuidString.prefix(5)) " +
            "entries=\(entries.count)"
        )
#endif
    }

    /// Returns a connected real client matching the panel. Loading entries stay
    /// in the pool so another panel can use them once the actual UI is ready.
    func claim(profileID: UUID, websiteDataStore: WKWebsiteDataStore) -> CmuxWebView? {
        let presentationHint = takeNextClaimPresentationHint()
        let targetWindow = presentationHint?.window
            ?? targetWindowProvider()
            ?? rememberedTargetWindow()
        if let targetWindow {
            lastTargetWindow = targetWindow
        }
        // Prefer the newest completed frame. The oldest entry absorbs the
        // WebContent process startup cost, while later serial entries paint
        // against an already-warm process.
        guard let index = entries.lastIndex(where: {
            guard $0.profileID == profileID,
                  $0.websiteDataStore === websiteDataStore,
                  ($0.host.preservesRenderingOnClaim
                      ? $0.host.window === targetWindow
                      : targetWindow == nil) else {
                return false
            }
            if case .finished = $0.loadState { return true }
            return false
        }) else {
            return nil
        }

        let entry = entries.remove(at: index)
        let webView = entry.webView
        webView.navigationDelegate = nil
        webView.onCodeSurfaceReady = nil
        webView.onCodeSurfaceUnready = nil
        webView.onCodeSurfaceFailed = nil
        webView.evaluateJavaScript(
            "window.cmuxCode?.stopPrewarmHealthMonitoring?.();",
            completionHandler: nil
        )
        if entry.host.preservesRenderingOnClaim {
            // Present the already-connected client in the old surface's exact
            // rectangle while SwiftUI creates the destination pane. The portal
            // then reparents this same view without crossing windows or
            // discarding WebKit's compositor surface.
            webView.codePrewarmHostView = entry.host.containerView
            let presentationFrame = presentationHint?.frame
                ?? presentationFrameProvider(entry.host.window)
                ?? entry.host.presentationFrame
            if let presentationFrame {
                Self.present(
                    entry.host.containerView,
                    webView: webView,
                    in: entry.host.window,
                    frame: presentationFrame
                )
            }
        } else {
            webView.removeFromSuperview()
            webView.isCodePrewarmAccessibilitySuppressed = false
            webView.browserPortalPrepareForHiddenHostAdoption()
            entry.host.containerView.removeFromSuperview()
            if entry.host.ownsWindow {
                entry.host.window.close()
            }
        }
#if DEBUG
        cmuxDebugLog(
            "code.warmer.claim remaining=\(entries.count) ready=\(readyCount)"
        )
#endif
        return webView
    }

    /// Captures the current workspace canvas before a Code workspace replaces
    /// it. Workspace construction happens before the new SwiftUI pane exists,
    /// so the next claim uses this exact window and frame instead of waiting for
    /// first-responder geometry to settle.
    func prepareNextWorkspaceClaim(in window: NSWindow) {
        lastTargetWindow = window
        let frame = Self.workspaceSurfaceFrame(in: window)
        nextClaimPresentationHint = ClaimPresentationHint(
            window: window,
            frame: frame,
            expiresAt: ProcessInfo.processInfo.systemUptime + 2
        )
#if DEBUG
        let frameDescription = frame.map {
            "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))"
        } ?? "nil"
        cmuxDebugLog(
            "code.warmer.prepareWorkspace entries=\(entries.count) " +
            "ready=\(readyCount) frame=\(frameDescription)"
        )
#endif
    }

    func discard(reason: String) {
        let discardedEntries = entries
        entries.removeAll()
        for entry in discardedEntries {
            tearDown(entry)
        }
#if DEBUG
        if !discardedEntries.isEmpty {
            cmuxDebugLog(
                "code.warmer.discard reason=\(reason) count=\(discardedEntries.count)"
            )
        }
#endif
    }

    static func preferredTargetWindow() -> NSWindow? {
        if let keyWindow = NSApp.keyWindow as? CmuxMainWindow,
           keyWindow.isVisible,
           !keyWindow.isMiniaturized {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow as? CmuxMainWindow,
           mainWindow.isVisible,
           !mainWindow.isMiniaturized {
            return mainWindow
        }
        return NSApp.windows.first(where: {
            $0 is CmuxMainWindow && $0.isVisible && !$0.isMiniaturized
        })
    }

    static func focusedSurfaceFrame(in window: NSWindow) -> NSRect? {
        guard let contentView = window.contentView else { return nil }

        let firstResponderView: NSView? = {
            if let editor = window.firstResponder as? NSTextView,
               editor.isFieldEditor,
               let delegateView = editor.delegate as? NSView {
                return delegateView
            }
            var responder = window.firstResponder
            while let current = responder {
                if let view = current as? NSView { return view }
                responder = current.nextResponder
            }
            return nil
        }()

        guard var candidate = firstResponderView, candidate.window === window else {
            return nil
        }
        while true {
            if candidate is WindowBrowserSlotView || candidate is GhosttySurfaceScrollView {
                return visibleFrame(of: candidate, in: contentView)
            }
            guard let superview = candidate.superview else { return nil }
            candidate = superview
        }
    }

    static func workspaceSurfaceFrame(in window: NSWindow) -> NSRect? {
        guard let contentView = window.contentView else { return nil }
        var frames: [NSRect] = []

        if let browserFrame = BrowserWindowPortalRegistry.visibleBrowserSurfaceFrame(in: window) {
            frames.append(browserFrame)
        }

        func collectVisibleSurfaces(in view: NSView) {
            guard !view.isHidden, view.alphaValue > 0.001 else { return }
            if view is WindowBrowserSlotView || view is GhosttySurfaceScrollView {
                if let frame = visibleFrame(of: view, in: contentView) {
                    frames.append(frame)
                }
                return
            }
            for subview in view.subviews {
                collectVisibleSurfaces(in: subview)
            }
        }

        collectVisibleSurfaces(in: contentView)
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    private static func visibleFrame(of view: NSView, in contentView: NSView) -> NSRect? {
        let converted = contentView.convert(view.bounds, from: view)
        let clipped = converted.intersection(contentView.bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        return clipped
    }

    private func rememberedTargetWindow() -> NSWindow? {
        guard let window = lastTargetWindow,
              !window.isMiniaturized,
              NSApp.windows.contains(where: { $0 === window }) else {
            lastTargetWindow = nil
            return nil
        }
        return window
    }

    private func takeNextClaimPresentationHint() -> ClaimPresentationHint? {
        defer { nextClaimPresentationHint = nil }
        guard let hint = nextClaimPresentationHint,
              hint.expiresAt >= ProcessInfo.processInfo.systemUptime,
              !hint.window.isMiniaturized,
              NSApp.windows.contains(where: { $0 === hint.window }) else {
            return nil
        }
        return hint
    }

    private static func applyTransparentBackground(to webView: WKWebView) {
        webView.wantsLayer = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.layer?.isOpaque = false
        webView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private static func makeHost(
        for webView: WKWebView,
        targetWindow: NSWindow?,
        presentationFrame: NSRect?
    ) -> Host {
        if let targetWindow,
           targetWindow.isVisible,
           !targetWindow.isMiniaturized,
           let contentView = targetWindow.contentView {
            let contentSize = presentationFrame?.size ?? contentView.bounds.size
            let size = NSSize(
                width: max(contentSize.width, 320),
                height: max(contentSize.height, 240)
            )
            let containerView = NSView(
                frame: NSRect(
                    x: -size.width - 64,
                    y: -size.height - 64,
                    width: size.width,
                    height: size.height
                )
            )
            containerView.identifier = NSUserInterfaceItemIdentifier("cmux.codeWebViewWarmer")
            containerView.setAccessibilityHidden(true)
            containerView.wantsLayer = true
            containerView.layer?.masksToBounds = true
            webView.frame = containerView.bounds
            webView.autoresizingMask = [.width, .height]
            containerView.addSubview(webView)
            if let firstSubview = contentView.subviews.first {
                contentView.addSubview(containerView, positioned: .below, relativeTo: firstSubview)
            } else {
                contentView.addSubview(containerView)
            }
            return Host(
                containerView: containerView,
                window: targetWindow,
                ownsWindow: false,
                preservesRenderingOnClaim: true,
                presentationFrame: presentationFrame
            )
        }

        return makeFallbackWindowHost(for: webView)
    }

    private static func makeFallbackWindowHost(for webView: WKWebView) -> Host {
        var size = NSSize(width: 1080, height: 760)
        if let contentSize = NSApp.mainWindow?.contentView?.bounds.size,
           contentSize.width >= 320,
           contentSize.height >= 240 {
            size = contentSize
        }
        let frame = NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.codeWebViewWarmer")
        window.hasShadow = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.isExcludedFromWindowsMenu = true

        let contentView = NSView(frame: frame)
        webView.frame = contentView.bounds
        webView.autoresizingMask = [.width, .height]
        contentView.addSubview(webView)
        window.contentView = contentView
        window.orderFrontRegardless()
        return Host(
            containerView: contentView,
            window: window,
            ownsWindow: true,
            preservesRenderingOnClaim: false,
            presentationFrame: nil
        )
    }

    private static func present(
        _ containerView: NSView,
        webView: CmuxWebView,
        in window: NSWindow,
        frame: NSRect
    ) {
        guard let contentView = window.contentView else { return }
        let clippedFrame = frame.intersection(contentView.bounds)
        guard !clippedFrame.isNull,
              clippedFrame.width >= 1,
              clippedFrame.height >= 1 else {
            return
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerView.frame = clippedFrame
        containerView.setAccessibilityHidden(false)
        webView.isCodePrewarmAccessibilitySuppressed = false
        containerView.isHidden = false
        contentView.addSubview(containerView, positioned: .above, relativeTo: nil)
        containerView.layoutSubtreeIfNeeded()
        CATransaction.commit()
        window.displayIfNeeded()
#if DEBUG
        let elapsedMilliseconds = Int(
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        )
        cmuxDebugLog(
            "code.warmer.presented elapsedMs=\(elapsedMilliseconds) " +
            "frame=\(Int(clippedFrame.minX)),\(Int(clippedFrame.minY)) " +
            "\(Int(clippedFrame.width))x\(Int(clippedFrame.height))"
        )
#endif
    }

    private func refreshTheme() {
        guard let script = CodeWebThemeSnapshot.current().applyingJavaScript() else { return }
        for entry in entries {
            Self.applyTransparentBackground(to: entry.webView)
            entry.webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func discard(webView: WKWebView, reason: String) {
        guard let index = entries.firstIndex(where: { $0.webView === webView }) else { return }
        let entry = entries.remove(at: index)
        tearDown(entry)
#if DEBUG
        cmuxDebugLog("code.warmer.discard reason=\(reason) count=1")
#endif
    }

    private func tearDown(_ entry: Entry) {
        let webView = entry.webView
        webView.navigationDelegate = nil
        webView.onCodeSurfaceReady = nil
        webView.onCodeSurfaceUnready = nil
        webView.onCodeSurfaceFailed = nil
        webView.codeSurfaceMessageHandler?.closeAll()
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: CodeSurfaceMessageHandler.name,
            contentWorld: .page
        )
        webView.codeSurfaceMessageHandler = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        entry.host.containerView.removeFromSuperview()
        if entry.host.ownsWindow {
            entry.host.window.close()
        }
    }

    func markReady(_ webView: WKWebView) {
        guard let index = entries.firstIndex(where: { $0.webView === webView }) else { return }
        var entry = entries[index]
        guard case .loading = entry.loadState else { return }
        entry.loadState = .finished
        entries[index] = entry
#if DEBUG
        let elapsedMilliseconds = Int(
            (ProcessInfo.processInfo.systemUptime - entry.startedAt) * 1_000
        )
        cmuxDebugLog(
            "code.warmer.actualReady elapsedMs=\(elapsedMilliseconds) " +
            "ready=\(readyCount)/\(entries.count)"
        )
#endif
        prewarm(
            profileID: entry.profileID,
            websiteDataStore: entry.websiteDataStore,
            workingDirectory: entry.workingDirectory,
            targetWindow: entry.host.preservesRenderingOnClaim ? entry.host.window : nil
        )
    }

    func markUnready(_ webView: WKWebView) {
        guard let index = entries.firstIndex(where: { $0.webView === webView }) else { return }
        var entry = entries[index]
        guard case .finished = entry.loadState else { return }
        entry.loadState = .loading
        entries[index] = entry
#if DEBUG
        cmuxDebugLog(
            "code.warmer.actualUnready ready=\(readyCount)/\(entries.count)"
        )
#endif
    }
}

extension CodeWebViewWarmer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
#if DEBUG
        guard entries.contains(where: { $0.webView === webView }) else { return }
        cmuxDebugLog("code.warmer.navigationFinished awaitingActualClient=true")
#endif
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        discard(webView: webView, reason: "load-failed")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        discard(webView: webView, reason: "provisional-load-failed")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        discard(webView: webView, reason: "webcontent-terminated")
    }
}
