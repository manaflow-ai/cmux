import AppKit
import CmuxSidebar
import ObjectiveC
import SwiftUI

/// Borderless nonactivating panel that floats the sidebar card above the
/// window's portal-hosted terminal views.
///
/// The terminal is not SwiftUI: portal hosting reparents every surface into a
/// `WindowTerminalHostView` that sits above the window's SwiftUI hosting view,
/// so nothing drawn inside ContentView's own tree can appear over live
/// terminal content, whatever its zIndex says. cmux's rich overlays solve
/// this with their own windows (the command palette, browser popups); the
/// peek card does the same. A child window also gives the card its own event
/// stream, which is what makes the hover holds reliable: inside the main
/// window, pointer events over the card's area belong to whatever hit-test
/// carve-outs the terminal host happens to have.
private var cmuxSuppressTerminalCursorRectsKey: UInt8 = 0

extension NSWindow {
    /// While true, portal-hosted terminal surfaces in this window register an
    /// arrow cursor rect instead of ghostty's shape. Set by the peek panel
    /// controller while the floating card accepts the pointer.
    var cmuxSuppressesTerminalCursorRects: Bool {
        get {
            (objc_getAssociatedObject(self, &cmuxSuppressTerminalCursorRectsKey) as? NSNumber)?.boolValue == true
        }
        set {
            objc_setAssociatedObject(
                self,
                &cmuxSuppressTerminalCursorRectsKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN
            )
        }
    }
}

final class SidebarPeekPanelWindow: NSPanel {
    // Never key or main: the parent keeps keyboard focus, so keystrokes keep
    // flowing to the terminal while the card is up, and clicking a row cannot
    // steal the window's key state out from under the peek gesture.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the child panel and keeps it glued to its parent window's leading
/// edge. One controller per main window, held by the bridge's coordinator.
@MainActor
final class SidebarPeekPanelWindowController {
    private var panel: SidebarPeekPanelWindow?
    private var hostingView: SidebarPeekPanelHostingView?
    private weak var parentWindow: NSWindow?
    // `nonisolated(unsafe)` so deinit can drop the tokens; every other access
    // is main-actor.
    private nonisolated(unsafe) var parentObservers: [NSObjectProtocol] = []
    private var lastContentWidth: CGFloat = 0
    private var lastMetrics: SidebarPeekPanelMetrics = .default
    /// Whether the previous update had the card revealed. Content pushes are
    /// skipped while hidden (repainting an invisible panel on every
    /// ContentView update is pure cost); the one push after reveal flips to
    /// false still lands so the exit animation runs.
    private var lastRevealed = false
    private var hasPushedContent = false
    /// Compositor blur radius last pushed to the panel window, so the CGS
    /// call only fires when the value (or the panel) changes.
    private var appliedBlurRadius: Int?
    /// Pending blur removal after the card hides; see `syncCompositorBlur`.
    private var blurResetTask: Task<Void, Never>?
    /// Trailing-edge coalescing for content pushes. ContentView can evaluate
    /// its body many times inside one runloop turn (worst during a workspace
    /// switch); the first push of a turn lands synchronously so clicks
    /// repaint instantly, and the rest collapse into one trailing push.
    private var didPushContentThisTurn = false
    private var pendingCoalescedContent: AnyView?

    /// Whether the panel is already attached to `window`, letting the bridge
    /// update synchronously instead of hopping the runloop.
    func isAttached(to window: NSWindow) -> Bool {
        parentWindow === window && panel?.parent === window
    }

    /// Extra room on the trailing edge so the card's SwiftUI shadow is not
    /// clipped by the panel's bounds. Kept slim on purpose: pointer events
    /// inside this window cannot fall through to the parent, so every point
    /// of margin is a point of terminal that stops responding while the
    /// card is up.
    private static let shadowMargin: CGFloat = 20

    /// The titlebar strip stays outside the panel so the traffic lights and
    /// titlebar controls in the parent window remain clickable while the
    /// card is up.
    private static var topExclusion: CGFloat {
        WindowChromeMetrics.appTitlebarHeight + 2
    }

    deinit {
        // Thread-safe by NotificationCenter contract; the panel itself is
        // torn down by orderOut in detach or by the parent window closing.
        for observer in parentObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func update(
        parent: NSWindow?,
        contentWidth: CGFloat,
        metrics: SidebarPeekPanelMetrics,
        acceptsMouse: Bool,
        glassBlurRadius: Int?,
        content: AnyView
    ) {
        guard let parent, parent.isVisible else {
            detach()
            return
        }
        lastContentWidth = contentWidth
        lastMetrics = metrics
        ensurePanel(parent: parent)
        guard let panel, let hostingView else { return }
        syncCompositorBlur(glassBlurRadius, revealed: acceptsMouse, panel: panel)
        // Push content only while the card shows (or on the hide transition,
        // which the slide-out animation needs). Pushing on every ContentView
        // update while hidden re-diffed the whole sidebar subtree during
        // workspace-switch churn, which is where the click-to-switch lag in
        // floating mode came from.
        if acceptsMouse || lastRevealed || !hasPushedContent {
            if !didPushContentThisTurn {
                didPushContentThisTurn = true
                hostingView.rootView = content
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.didPushContentThisTurn = false
                    if let pending = self.pendingCoalescedContent {
                        self.pendingCoalescedContent = nil
                        self.hostingView?.rootView = pending
                    }
                }
            } else {
                pendingCoalescedContent = content
            }
            hasPushedContent = true
        }
        lastRevealed = acceptsMouse
        // When the card is not revealed the panel must be transparent to the
        // pointer, or it would swallow the very edge hovers that arm the
        // reveal in the parent window below it.
        panel.ignoresMouseEvents = !acceptsMouse
        panel.appearance = parent.appearance
        // Terminal cursor rects yield to the card while it can be pointed
        // at, and come back the moment it cannot.
        if parent.cmuxSuppressesTerminalCursorRects != acceptsMouse {
            parent.cmuxSuppressesTerminalCursorRects = acceptsMouse
            parent.resetCursorRects()
        }
        layoutPanel()
    }

    /// Mirrors the docked ground's compositor blur onto the card's own window,
    /// but only while the card is showing. The panel stays attached over the
    /// leading column even when hidden, and a transparent window with a blur
    /// radius blurs everything beneath it: with the card away that would be
    /// the docked sidebar's own rows. Removal waits for the exit slide so the
    /// card does not go clear mid-flight.
    private func syncCompositorBlur(_ radius: Int?, revealed: Bool, panel: NSWindow) {
        if radius == nil {
            // No blur wanted at all (docked, or glass off): drop it now rather
            // than after the exit delay, or the docked rows underneath start
            // out blurred.
            blurResetTask?.cancel()
            blurResetTask = nil
            applyCompositorBlur(nil, to: panel)
        } else if revealed {
            blurResetTask?.cancel()
            blurResetTask = nil
            applyCompositorBlur(radius, to: panel)
        } else if appliedBlurRadius != nil, blurResetTask == nil {
            blurResetTask = Task { @MainActor [weak self] in
                guard (try? await Task.sleep(for: .milliseconds(320))) != nil else { return }
                guard let self, let panel = self.panel else { return }
                self.blurResetTask = nil
                self.applyCompositorBlur(nil, to: panel)
            }
        }
    }

    private func applyCompositorBlur(_ radius: Int?, to panel: NSWindow) {
        guard radius != appliedBlurRadius else { return }
        guard panel.windowNumber > 0 else { return }
        WindowBackgroundComposition.blurController.setBackgroundBlur(
            windowNumber: panel.windowNumber,
            radius: radius ?? 0
        )
        appliedBlurRadius = radius
    }

    private func ensurePanel(parent: NSWindow) {
        if let panel, parentWindow === parent, panel.parent === parent {
            return
        }
        detach()

        let hosting = SidebarPeekPanelHostingView(rootView: AnyView(EmptyView()))
        hosting.autoresizingMask = [.width, .height]

        let panel = SidebarPeekPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentView = hosting
        panel.ignoresMouseEvents = true

        parent.addChildWindow(panel, ordered: .above)

        self.panel = panel
        self.hostingView = hosting
        self.parentWindow = parent

        // Child windows ride along on parent moves, but a resize changes the
        // region the panel must cover, and a screen change can do both.
        let center = NotificationCenter.default
        parentObservers = [
            center.addObserver(
                forName: NSWindow.didResizeNotification, object: parent, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutPanel() }
            },
            center.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: parent, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutPanel() }
            },
            center.addObserver(
                forName: NSWindow.willCloseNotification, object: parent, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.detach() }
            },
        ]
        layoutPanel()
    }

    /// Pins the panel over the parent's leading content region: full height,
    /// wide enough for the inset card plus shadow bleed.
    private func layoutPanel() {
        guard let panel, let parent = parentWindow else { return }
        let parentContent = parent.contentRect(forFrameRect: parent.frame)
        let width = lastMetrics.leadingInset + lastContentWidth + Self.shadowMargin
        let height = max(0, parentContent.height - Self.topExclusion)
        let frame = NSRect(
            x: parentContent.minX,
            y: parentContent.minY,
            width: min(width, parentContent.width),
            height: height
        )
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    private func detach() {
        for observer in parentObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        parentObservers = []
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        hostingView = nil
        parentWindow = nil
        appliedBlurRadius = nil
        blurResetTask?.cancel()
        blurResetTask = nil
    }
}

/// Hosting view that keeps the pointer honest over the card.
///
/// The terminal underneath registers an I-beam cursor rect with the key
/// window, and this panel is deliberately never key, so its own cursor rects
/// are ignored: AppKit keeps applying the terminal's I-beam straight through
/// the card. Re-asserting the arrow on entry and movement is the only lever
/// a non-key window has.
private final class SidebarPeekPanelHostingView: NSHostingView<AnyView> {
    private var cursorTrackingArea: NSTrackingArea?

    @MainActor required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("SidebarPeekPanelHostingView does not support NSCoder")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        NSCursor.arrow.set()
    }
}

/// Mounts the panel controller into SwiftUI: a zero-sized anchor that tells
/// the controller which window to attach to and pushes fresh card content on
/// every ContentView update, so bindings and store references inside the card
/// stay live without the panel needing its own environment plumbing.
struct SidebarPeekPanelBridge: NSViewRepresentable {
    let contentWidth: CGFloat
    let metrics: SidebarPeekPanelMetrics
    let acceptsMouse: Bool
    /// Compositor blur for the card's window; nil when the card blurs
    /// through its own material instead.
    let glassBlurRadius: Int?
    let content: AnyView

    @MainActor
    final class Coordinator {
        let controller = SidebarPeekPanelWindowController()
    }

    final class AnchorView: NSView {
        var onWindowChange: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnchorView {
        AnchorView(frame: .zero)
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        let controller = context.coordinator.controller
        let contentWidth = contentWidth
        let metrics = metrics
        let acceptsMouse = acceptsMouse
        let glassBlurRadius = glassBlurRadius
        let content = content
        let push: @MainActor () -> Void = { [weak view] in
            controller.update(
                parent: view?.window,
                contentWidth: contentWidth,
                metrics: metrics,
                acceptsMouse: acceptsMouse,
                glassBlurRadius: glassBlurRadius,
                content: content
            )
        }
        view.onWindowChange = {
            // Window attachment lands outside our own update pass.
            Task { @MainActor in push() }
        }
        if let window = view.window, controller.isAttached(to: window) {
            // Already attached: update in place so a click inside the panel
            // repaints on this runloop turn, not the next. The async hop is
            // only needed while attaching, when the window hierarchy itself
            // mutates.
            push()
        } else {
            Task { @MainActor in push() }
        }
    }
}
