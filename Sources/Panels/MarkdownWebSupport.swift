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

/// Owns the Markdown viewer's AppKit/WebKit lifecycle state.
///
/// `NSView` callbacks can arrive while SwiftUI is laying out an ancestor. The
/// coordinator records those callbacks synchronously, then coalesces the one
/// WebKit action that is safe to perform after the host transaction unwinds.
/// Keeping the state machine here gives window, geometry, and tab-visibility
/// transitions one owner and makes the transition contract independently
/// testable without relying on WebKit's pixel output.
@MainActor
final class MarkdownWebRenderingCoordinator {
    /// The one deferred platform action emitted by the lifecycle state machine.
    enum Action: Equatable {
        case hide(reason: String)
        case refresh(reason: String, forceLifecycleRefresh: Bool)
    }

    private let scheduler: MainActorDeferredActionScheduler
    private let isActuallyVisible: @MainActor () -> Bool
    private let applyAction: @MainActor (Action) -> Void
    private let onReenterWindow: @MainActor () -> Void

    private var attachedToWindow = false
    private var desiredVisibility = true
    private var needsRenderingReattach = false
    private var renderingStateIsHidden = false
    private var lastObservedBoundsSize: CGSize
    private var pendingRefreshReason = "initial"
    private var pendingForceLifecycleRefresh = false
    private var pendingWindowReentryNotification = false

    /// Creates a coordinator with an injectable action sink for transition tests.
    init(
        initialBoundsSize: CGSize,
        scheduler: MainActorDeferredActionScheduler? = nil,
        isActuallyVisible: @escaping @MainActor () -> Bool,
        applyAction: @escaping @MainActor (Action) -> Void,
        onReenterWindow: @escaping @MainActor () -> Void = {}
    ) {
        self.scheduler = scheduler ?? MainActorDeferredActionScheduler()
        self.isActuallyVisible = isActuallyVisible
        self.applyAction = applyAction
        self.onReenterWindow = onReenterWindow
        lastObservedBoundsSize = initialBoundsSize
    }

    /// Records a view-to-window transition without entering WebKit inline.
    func viewDidMoveToWindow(isAttached: Bool) {
        attachedToWindow = isAttached
        if isAttached {
            // Reparenting can preserve SwiftUI identity while WebKit loses its
            // in-window layer state. Always repair on the deferred turn.
            pendingWindowReentryNotification = true
            schedule(reason: "viewDidMoveToWindow.visible", forceLifecycleRefresh: true)
        } else {
            needsRenderingReattach = true
            pendingWindowReentryNotification = false
            schedule(reason: "viewDidMoveToWindow.hidden", forceLifecycleRefresh: false)
        }
    }

    /// Records an exact geometry change. Fractional-point divider movement is
    /// meaningful to WebKit, so no epsilon is applied here.
    func layoutDidChange(to boundsSize: CGSize) {
        let sizeChanged = lastObservedBoundsSize != boundsSize
        lastObservedBoundsSize = boundsSize
        if sizeChanged {
            schedule(reason: "boundsChanged", forceLifecycleRefresh: false)
        } else if needsRenderingReattach,
                  desiredVisibility,
                  attachedToWindow,
                  isActuallyVisible() {
            // SwiftUI can finish an opacity/hidden transition without changing
            // the view's size. A settled layout callback is the platform signal
            // that lets a previously hidden repair try again.
            schedule(reason: "visibilitySettled", forceLifecycleRefresh: true)
        }
    }

    /// Requests a lifecycle-aware repaint after an AppKit live resize ends.
    func viewDidEndLiveResize() {
        schedule(reason: "viewDidEndLiveResize", forceLifecycleRefresh: true)
    }

    /// Records whether SwiftUI intends this keep-alive viewer to be visible.
    func setVisibleInUI(_ visible: Bool) {
        let changed = desiredVisibility != visible
        desiredVisibility = visible
        if visible {
            if changed ||
                needsRenderingReattach ||
                renderingStateIsHidden ||
                pendingWindowReentryNotification {
                schedule(reason: "visibility.visible", forceLifecycleRefresh: true)
            }
        } else if changed {
            needsRenderingReattach = true
            schedule(reason: "visibility.hidden", forceLifecycleRefresh: false)
        }
    }

    /// Replaces the pending action so a resize burst produces one settled pass.
    private func schedule(reason: String, forceLifecycleRefresh: Bool) {
        pendingRefreshReason = reason
        pendingForceLifecycleRefresh = pendingForceLifecycleRefresh || forceLifecycleRefresh
        // The queued action reads the latest state when it runs. Keep one
        // scheduler task for a resize/visibility burst instead of repeatedly
        // cancelling and recreating MainActor tasks while AppKit is laying out.
        guard !scheduler.isScheduled else { return }
        scheduler.schedule { [weak self] in
            self?.performPendingAction()
        }
    }

    /// Applies the latest state snapshot after the host layout callback returns.
    private func performPendingAction() {
        let forceLifecycleRefresh = pendingForceLifecycleRefresh
        pendingForceLifecycleRefresh = false
        let reason = pendingRefreshReason

        guard desiredVisibility, attachedToWindow else {
            applyHiddenAction(reason: reason)
            return
        }

        guard isActuallyVisible() else {
            // AppKit may still be completing the hide/unhide transaction. Keep
            // the reattach intent; the next settled geometry/visibility callback
            // will run this same state transition again.
            needsRenderingReattach = true
            pendingForceLifecycleRefresh = pendingForceLifecycleRefresh || forceLifecycleRefresh
            return
        }

        let shouldReenter = forceLifecycleRefresh || needsRenderingReattach || renderingStateIsHidden
        if shouldReenter {
            needsRenderingReattach = false
            renderingStateIsHidden = false
        }
        applyAction(.refresh(reason: reason, forceLifecycleRefresh: shouldReenter))

        if pendingWindowReentryNotification {
            pendingWindowReentryNotification = false
            onReenterWindow()
        }
    }

    /// Moves WebKit out of its in-window lifecycle exactly once per hide period.
    private func applyHiddenAction(reason: String) {
        guard !renderingStateIsHidden else { return }
        renderingStateIsHidden = true
        needsRenderingReattach = true
        applyAction(.hide(reason: reason))
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

    /// The coordinator is the only owner of deferred WebKit lifecycle work.
    private var renderingCoordinator: MarkdownWebRenderingCoordinator?
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
        renderingCoordinator = makeRenderingCoordinator(initialBoundsSize: bounds.size)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        Self.installEditableFocusTracking(on: configuration.userContentController)
        renderingCoordinator = makeRenderingCoordinator(initialBoundsSize: bounds.size)
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
        renderingCoordinator?.viewDidMoveToWindow(isAttached: window != nil)
        if window == nil {
            // This callback only records renderer health. All WebKit lifecycle
            // selectors and layout/display work stay on the deferred path.
            onLeaveWindow?()
        }
    }

    override func layout() {
        super.layout()
        // A divider/window resize can leave a live WKWebView with valid scroll
        // geometry but stale backing tiles. Invalidate and repair after this
        // layout callback returns; never flush the SwiftUI-owned ancestor here.
        renderingCoordinator?.layoutDidChange(to: bounds.size)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        renderingCoordinator?.viewDidEndLiveResize()
    }

    /// Updates the SwiftUI visibility intent for this viewer. Workspace panes
    /// keep all tabs alive, so an opacity-hidden tab must explicitly leave
    /// WebKit's in-window lifecycle or ProcessThrottler may park its process;
    /// the selected tab gets a deferred enter/paint pass on reveal.
    func setVisibleInUI(_ visible: Bool) {
        renderingCoordinator?.setVisibleInUI(visible)
    }

    private func makeRenderingCoordinator(initialBoundsSize: CGSize) -> MarkdownWebRenderingCoordinator {
        MarkdownWebRenderingCoordinator(
            initialBoundsSize: initialBoundsSize,
            isActuallyVisible: { [weak self] in
                guard let self else { return false }
                return self.window != nil && !self.isHiddenOrHasHiddenAncestor
            },
            applyAction: { [weak self] action in
                self?.applyRenderingAction(action)
            },
            onReenterWindow: { [weak self] in
                self?.onReenterWindow?()
            }
        )
    }

    private func applyRenderingAction(_ action: MarkdownWebRenderingCoordinator.Action) {
        switch action {
        case .hide:
            callVoidSelectorIfAvailable("viewDidHide")
            callVoidSelectorIfAvailable("_exitInWindow")
        case let .refresh(_, forceLifecycleRefresh):
            if forceLifecycleRefresh {
                callVoidSelectorIfAvailable("viewDidUnhide")
                callVoidSelectorIfAvailable("_enterInWindow")
                callVoidSelectorIfAvailable("_endDeferringViewInWindowChangesSync")
            }

            needsLayout = true
            needsDisplay = true
            setNeedsDisplay(bounds)
            // This is deliberately below the deferred scheduler boundary. It
            // flushes only the Markdown WebKit view after SwiftUI/AppKit has
            // unwound, so no enclosing scroll view or NSHostingView is
            // synchronously re-entered.
            layoutSubtreeIfNeeded()
            displayIfNeeded()
        }
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

    /// The live preview web view, for find-in-page script evaluation.
    /// `nil` until the renderer has been mounted once.
    var findScriptWebView: WKWebView? {
        ownedCoordinator.webView
    }

    /// Invoked after the shell re-renders the markdown content (initial load,
    /// content change, or crash recovery). Find highlights are DOM `<mark>`
    /// wrappers that a re-render wipes, so an active search must re-run.
    var onMarkdownRendered: (() -> Void)? {
        get { ownedCoordinator.onMarkdownRendered }
        set { ownedCoordinator.onMarkdownRendered = newValue }
    }

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

    func readSurfaceSelection(filePath: String) async -> SurfaceSelectionReadResult {
        await ownedCoordinator.readSurfaceSelection(filePath: filePath)
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
