import AppKit
import CmuxFoundation
import WebKit

@MainActor
final class WeakMarkdownScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
final class MarkdownWebView: WKWebView {
    var onPointerDown: (() -> Void)?
    /// Invoked when the view leaves its window (the detach half of a pane
    /// re-parent). Lets the renderer coordinator record whether the document
    /// was healthy at detach time so re-entry recovery can tell a detach
    /// artifact apart from an attached crash loop.
    var onLeaveWindow: (() -> Void)?
    /// Invoked when the view re-enters a window after being detached. Lets the
    /// renderer coordinator recover content WebKit dropped while the view was
    /// out of the window (e.g. a pane drag re-parented the hosting views).
    var onReenterWindow: (() -> Void)?

#if DEBUG
    /// Test-only observation point for the WebKit repaint pass. The callback
    /// is intentionally attached to the actual subtree refresh rather than to
    /// a scheduler so tests can distinguish an inline host re-entry flush from
    /// the deferred repair turn.
    var renderingRefreshProbeForTesting: (() -> Void)?
#endif

    /// AppKit/SwiftUI can invoke layout and move-to-window callbacks while an
    /// ancestor `NSHostingView` is still rendering. Keep WebKit lifecycle and
    /// subtree flushes behind this scheduler so those callbacks only invalidate
    /// state and never synchronously re-enter the host hierarchy.
    private let renderingRefreshScheduler = MainActorDeferredActionScheduler()
    private var needsRenderingReattach = false
    private var desiredVisibility = true
    private var webKitRenderingStateIsHidden = false
    private var lastObservedBoundsSize: CGSize = .zero
    private var pendingRefreshReason = "initial"
    private var pendingForceLifecycleRefresh = false
    private var pendingWindowReentryNotification = false
    private var windowResizeObserver: NSObjectProtocol?
    private var editableFocusStateConfirmed = false
    private var editableElementFocused = false
    private let viewerNavigationKeyRouter = ViewerNavigationKeyRouter(actions: [
        .diffViewerScrollDown, .diffViewerScrollUp,
        .diffViewerScrollHalfPageDown, .diffViewerScrollHalfPageUp,
        .diffViewerScrollDownEmacs, .diffViewerScrollUpEmacs,
        .diffViewerScrollToBottom, .diffViewerScrollToTop,
    ])

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        Self.installEditableFocusTracking(on: configuration.userContentController)
        super.init(frame: frame, configuration: configuration)
        lastObservedBoundsSize = bounds.size
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        Self.installEditableFocusTracking(on: configuration.userContentController)
        lastObservedBoundsSize = bounds.size
    }

    deinit {
        if let windowResizeObserver {
            NotificationCenter.default.removeObserver(windowResizeObserver)
        }
        renderingRefreshScheduler.cancel()
    }

    private static func installEditableFocusTracking(on controller: WKUserContentController) {
        let name = MarkdownEditableFocusMessageHandler.name
        controller.add(MarkdownEditableFocusMessageHandler.shared, name: name)
        controller.addUserScript(WKUserScript(
            source: """
            (() => {
              const handler = window.webkit?.messageHandlers?.['\(name)'];
              if (!handler) return;
              const deepestActiveElement = () => {
                let element = document.activeElement;
                while (element?.shadowRoot?.activeElement) {
                  element = element.shadowRoot.activeElement;
                }
                return element;
              };
              const publish = () => {
                const element = deepestActiveElement();
                const editable = !!element?.closest?.("input, textarea, select, [contenteditable]:not([contenteditable='false'])");
                handler.postMessage({ editable });
              };
              document.addEventListener('focusin', publish, true);
              document.addEventListener('focusout', () => queueMicrotask(publish), true);
              document.addEventListener('pointerdown', () => requestAnimationFrame(publish), true);
              document.addEventListener('DOMContentLoaded', publish, { once: true });
              publish();
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    func markdownEditableFocusDidChange(_ editable: Bool) {
        editableFocusStateConfirmed = true
        editableElementFocused = editable
        if editable {
            viewerNavigationKeyRouter.reset()
        }
    }

    var isViewerNavigationEditableElementFocused: Bool {
        editableElementFocused
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func mouseDown(with event: NSEvent) {
        editableFocusStateConfirmed = false
        onPointerDown?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleViewerNavigationKey(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            editableFocusStateConfirmed = false
        }
        if handleViewerNavigationKey(event) {
            return
        }
        super.keyDown(with: event)
    }

    func handleViewerNavigationKey(_ event: NSEvent) -> Bool {
        guard cmuxOwnsKeyEvent(event),
              editableFocusStateConfirmed,
              !editableElementFocused else {
            viewerNavigationKeyRouter.reset()
            return false
        }
        return viewerNavigationKeyRouter.handle(event, isAllowed: { action, event in
            AppDelegate.shared?.shortcutWhenClauseAllows(action: action, event: event) ?? true
        }, perform: { [weak self] action in
            self?.performViewerNavigationAction(action)
        })
    }

    private func performViewerNavigationAction(_ action: KeyboardShortcutSettings.Action) {
        evaluateJavaScript("window.__cmuxPerformViewerNavigationAction?.('\(action.rawValue)')")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowResizeObserver()
        if window == nil {
            // Leaving the window (the detach half of a pane re-parent) is only
            // a state transition here. Calling WebKit's private lifecycle
            // selectors inline can re-enter the surrounding NSHostingView.
            needsRenderingReattach = true
            pendingWindowReentryNotification = false
            scheduleRenderingRefresh(reason: "viewDidMoveToWindow.hidden", forceLifecycleRefresh: false)
            onLeaveWindow?()
        } else {
            installWindowResizeObserver(for: window)
            // A view can be reparented without changing its SwiftUI identity.
            // Re-entering must therefore always get a deferred WebKit refresh;
            // the coordinator callback is delivered in that same safe turn.
            pendingWindowReentryNotification = true
            scheduleRenderingRefresh(reason: "viewDidMoveToWindow.visible", forceLifecycleRefresh: true)
        }
    }

    override func layout() {
        let previousSize = lastObservedBoundsSize
        let currentSize = bounds.size
        lastObservedBoundsSize = currentSize
        super.layout()

        guard !Self.isApproximatelyEqual(previousSize, currentSize) else { return }
        // A divider/window resize can leave a live WKWebView with valid scroll
        // geometry but stale backing tiles. Invalidate and repair after this
        // layout callback returns; never flush the SwiftUI-owned ancestor here.
        scheduleRenderingRefresh(reason: "boundsChanged", forceLifecycleRefresh: false)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        scheduleRenderingRefresh(reason: "viewDidEndLiveResize", forceLifecycleRefresh: true)
    }

    /// Updates the SwiftUI visibility intent for this viewer. Workspace panes
    /// keep all tabs alive, so an opacity-hidden tab must explicitly leave
    /// WebKit's in-window lifecycle or ProcessThrottler may park its process;
    /// the selected tab gets a deferred enter/paint pass on reveal.
    func setVisibleInUI(_ visible: Bool) {
        guard desiredVisibility != visible else { return }
        desiredVisibility = visible
        if visible {
            scheduleRenderingRefresh(reason: "visibility.visible", forceLifecycleRefresh: true)
        } else {
            needsRenderingReattach = true
            scheduleRenderingRefresh(reason: "visibility.hidden", forceLifecycleRefresh: false)
        }
    }

    private func scheduleRenderingRefresh(
        reason: String,
        forceLifecycleRefresh: Bool
    ) {
        pendingRefreshReason = reason
        pendingForceLifecycleRefresh = pendingForceLifecycleRefresh || forceLifecycleRefresh
        renderingRefreshScheduler.schedule { [weak self] in
            guard let self else { return }
            let forceLifecycleRefresh = self.pendingForceLifecycleRefresh
            let reason = self.pendingRefreshReason
            self.pendingForceLifecycleRefresh = false
            self.performRenderingRefresh(
                reason: reason,
                forceLifecycleRefresh: forceLifecycleRefresh
            )
            if self.pendingWindowReentryNotification {
                self.pendingWindowReentryNotification = false
                self.onReenterWindow?()
            }
        }
    }

    private func performRenderingRefresh(reason: String, forceLifecycleRefresh: Bool) {
        guard desiredVisibility, window != nil else {
            applyHiddenRenderingState(reason: reason)
            return
        }
        guard !isHiddenOrHasHiddenAncestor else {
            // `viewDidUnhide`/the next visibility update will retry once the
            // SwiftUI opacity/hidden transition has completed.
            needsRenderingReattach = true
            return
        }

        let shouldReenter = forceLifecycleRefresh || needsRenderingReattach || webKitRenderingStateIsHidden
        if shouldReenter {
            callVoidSelectorIfAvailable("viewDidUnhide")
            callVoidSelectorIfAvailable("_enterInWindow")
            callVoidSelectorIfAvailable("_endDeferringViewInWindowChangesSync")
            needsRenderingReattach = false
            webKitRenderingStateIsHidden = false
        }

        needsLayout = true
        needsDisplay = true
        setNeedsDisplay(bounds)
#if DEBUG
        renderingRefreshProbeForTesting?()
#endif
        // This is deliberately below the deferred scheduler boundary. It
        // flushes only the WebKit-owned subtree after SwiftUI/AppKit has
        // unwound, so no NSHostingView ancestor is synchronously re-entered.
        layoutSubtreeIfNeeded()
        displayIfNeeded()
    }

    private func applyHiddenRenderingState(reason _: String) {
        guard !webKitRenderingStateIsHidden else { return }
        callVoidSelectorIfAvailable("viewDidHide")
        callVoidSelectorIfAvailable("_exitInWindow")
        needsRenderingReattach = true
        webKitRenderingStateIsHidden = true
    }

    private func installWindowResizeObserver(for window: NSWindow?) {
        guard let window else { return }
        windowResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleRenderingRefresh(
                    reason: "windowDidEndLiveResize",
                    forceLifecycleRefresh: true
                )
            }
        }
    }

    private func removeWindowResizeObserver() {
        guard let windowResizeObserver else { return }
        NotificationCenter.default.removeObserver(windowResizeObserver)
        self.windowResizeObserver = nil
    }

    private static func isApproximatelyEqual(_ lhs: CGSize, _ rhs: CGSize, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.width - rhs.width) <= epsilon && abs(lhs.height - rhs.height) <= epsilon
    }

    /// Calls a private WKWebView lifecycle selector when present. Guarded by
    /// `responds(to:)` so it degrades to a no-op if the selector is removed.
    private func callVoidSelectorIfAvailable(_ rawSelector: String) {
        let selector = NSSelectorFromString(rawSelector)
        guard responds(to: selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        fn(self, selector)
    }
}

struct MarkdownWebTheme: Equatable {
    let isDark: Bool
    let background: String
    let mutedBackground: String
    let neutralMutedBackground: String
    let border: String
    let mutedBorder: String

    static func resolve(backgroundColor: NSColor) -> MarkdownWebTheme {
        let base = backgroundColor.markdownOpaqueSRGB
        let isDark = !base.isLightColor
        let overlayColor: NSColor = isDark ? .white : .black
        let muted = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.09 : 1.06,
            of: overlayColor
        )
        let neutralMuted = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.35 : 1.20,
            of: overlayColor
        )
        let border = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.92 : 1.43,
            of: overlayColor
        )
        return MarkdownWebTheme(
            isDark: isDark,
            background: "transparent",
            mutedBackground: muted.markdownCSSColor,
            neutralMutedBackground: neutralMuted.markdownCSSColor,
            border: border.markdownCSSColor,
            mutedBorder: border.withAlphaComponent(border.alphaComponent * 0.70).markdownCSSColor
        )
    }
}

/// Panel-owned renderer session for a markdown preview.
///
/// SwiftUI may recreate `MarkdownWebRenderer` wrappers during split/tab layout
/// updates. The session keeps the WebKit coordinator identity tied to the
/// logical `MarkdownPanel` instead of the transient representable instance.
@MainActor
final class MarkdownRendererSession {
    private let ownedCoordinator = MarkdownWebRenderer.Coordinator()

    func coordinator(
        panelId: UUID,
        workspaceId: UUID,
        filePath: String
    ) -> MarkdownWebRenderer.Coordinator {
        ownedCoordinator.bind(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
        return ownedCoordinator
    }

    func close() {
        ownedCoordinator.close()
    }

    func renderedHTML(markdown: String? = nil) async -> String? {
        await ownedCoordinator.renderedHTML(markdown: markdown)
    }

    func renderedText() async -> String? {
        await ownedCoordinator.renderedText()
    }
}

extension NSColor {
    var markdownOpaqueSRGB: NSColor {
        (usingColorSpace(.sRGB) ?? self).withAlphaComponent(1)
    }

    var markdownCSSColor: String {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let r = min(255, max(0, Int((red * 255).rounded())))
        let g = min(255, max(0, Int((green * 255).rounded())))
        let b = min(255, max(0, Int((blue * 255).rounded())))
        let a = min(1, max(0, alpha))
        return String(format: "rgba(%d, %d, %d, %.3f)", r, g, b, Double(a))
    }

    func markdownThemeOverlay(targetContrast: CGFloat, of color: NSColor) -> NSColor {
        let base = markdownOpaqueSRGB
        let overlay = color.markdownOpaqueSRGB
        var low: CGFloat = 0
        var high: CGFloat = 1
        var result: CGFloat = 1

        for _ in 0..<18 {
            let mid = (low + high) / 2
            let candidate = base.blended(withFraction: mid, of: overlay) ?? base
            if candidate.markdownContrastRatio(with: base) < Double(targetContrast) {
                low = mid
            } else {
                high = mid
                result = mid
            }
        }

        return overlay.withAlphaComponent(result)
    }

    var markdownRelativeLuminance: Double {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            if value <= 0.04045 {
                return value / 12.92
            }
            return pow((value + 0.055) / 1.055, 2.4)
        }

        return (0.2126 * linear(red)) + (0.7152 * linear(green)) + (0.0722 * linear(blue))
    }

    func markdownContrastRatio(with other: NSColor) -> Double {
        let first = markdownRelativeLuminance
        let second = other.markdownRelativeLuminance
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
