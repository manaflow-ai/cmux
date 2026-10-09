import AppKit
import Foundation
import QuartzCore

/// The docked sidebar toggle as a render-server slide.
///
/// Sweeping the real layout width cost a SwiftUI relayout, a split relayout
/// and a terminal grid resize on every frame. The slide instead moves the
/// window content root and the portal hosts above it (terminals, browsers)
/// as one rigid body, with one Core Animation spring on
/// `transform.translation.x` per layer, so the sidebar edge, the terminal's
/// leading edge and the pane chrome cannot drift apart, and nothing runs on
/// the main thread while it moves.
///
/// `SidebarToggleSlideMachine` decides what happens; this type carries it
/// out. Layout changes at most once per landed toggle, always at the wide
/// end, through `SidebarLayoutModel.docksSidebar` (read only by small
/// wrappers), committed with the divider drag's atomic recipe. The heavier
/// `SidebarState.isVisible` follows once the motion is over.
@MainActor
final class SidebarToggleAnimator: ObservableObject {
    private static let animationKey = "cmux.sidebarToggleSlide"

    private weak var sidebarState: SidebarState?
    private weak var layout: SidebarLayoutModel?
    private var window: () -> NSWindow? = { nil }
    private var canSlide: () -> Bool = { false }
    private var trailingStillWidth: () -> CGFloat = { 0 }
    private var isPeekPresenting: () -> Bool = { false }
    /// Applies what else follows the docked layout (minimal mode's tab bar
    /// inset) inside the same atomic commit.
    private var dockedLayoutWillCommit: (Bool) -> Void = { _ in }
    /// How much further right the tab bar's first tab rests hidden.
    private var tabBarInsetDelta: () -> CGFloat = { 0 }
    /// A hide's docked pane rects, taken before the hidden layout commits.
    private var pendingDocked: SidebarSlidePaneLayout?
    /// How many action buttons a pane's tab bar shows on its trailing end.
    private var splitButtonCount: () -> Int = { 0 }
    /// The last hide's hidden and docked pane layouts: a show over the same
    /// hidden layout lands on exactly that docked one.
    private var paneLayouts: (hidden: SidebarSlidePaneLayout, docked: SidebarSlidePaneLayout, width: CGFloat)?
    private var machine = SidebarToggleSlideMachine(docked: true)
    /// What carries the running slide, captured when it starts and kept for
    /// every retarget until it lands.
    private var session: SidebarToggleSlideSession?
    private var layoutObserver: NSObjectProtocol?
    /// Effects are being carried out; a press arriving meanwhile (the atomic
    /// commit runs the run loop once) waits its turn.
    private var isExecuting = false
    private var queuedRequests: [Bool] = []
    /// The animator itself is committing `isVisible`.
    private var isCommittingVisibility = false

    func install(
        sidebarState: SidebarState,
        layout: SidebarLayoutModel,
        window: @escaping () -> NSWindow?,
        canSlide: @escaping () -> Bool,
        trailingStillWidth: @escaping () -> CGFloat,
        isPeekPresenting: @escaping () -> Bool,
        dockedLayoutWillCommit: @escaping (Bool) -> Void,
        tabBarInsetDelta: @escaping () -> CGFloat,
        splitButtonCount: @escaping () -> Int
    ) {
        self.sidebarState = sidebarState
        self.layout = layout
        self.window = window
        self.canSlide = canSlide
        self.trailingStillWidth = trailingStillWidth
        self.isPeekPresenting = isPeekPresenting
        self.dockedLayoutWillCommit = dockedLayoutWillCommit
        self.tabBarInsetDelta = tabBarInsetDelta
        self.splitButtonCount = splitButtonCount
        // A re-install drops any running slide; `reset` keeps the generation
        // counting, so a late stop from the old slide stays stale.
        if session != nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            removeSlideAnimations()
            CATransaction.commit()
        }
        queuedRequests.removeAll()
        machine.reset(visible: sidebarState.isVisible)
        layout.docksSidebar = sidebarState.isVisible
        sidebarState.animatedVisibilityOrchestrator = { [weak self] targetVisible in
            self?.request(visible: targetVisible) ?? false
        }
        sidebarState.visibilityDidCommit = { [weak self] visible in
            self?.visibilityDidCommit(visible)
        }
#if DEBUG
        SidebarToggleSlideProbe.installTrigger(for: self)
#endif
    }

    /// Returns true when the toggle was consumed by a slide; false hands it
    /// back to the instant path.
    private func request(visible: Bool) -> Bool {
        guard let sidebarState, let layout else { return false }
        // A slide whose spring is long over but never reported its stop (its
        // layer left the tree) lands before this press, so a lost callback
        // cannot strand the toggle in retarget-only mode.
        if !isExecuting, let slide = machine.slide,
           CACurrentMediaTime() > slide.begin + slide.duration / Double(Self.speed) + 0.1 {
            land(generation: slide.generation)
        }
        let isSliding = machine.slide != nil
        guard sidebarState.presentationMode == .docked,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              canSlide(),
              let window = window(),
              isSliding || Self.slidingViews(in: window) != nil else {
            return false
        }
        // Docking over an already-revealed peek card swaps in place: the
        // card is where the pane belongs, so any slide would be a ghost.
        if !isSliding, visible, isPeekPresenting() { return false }
        if isExecuting {
            queuedRequests.append(visible)
            sidebarState.pendingVisibility = visible
            return true
        }
        SidebarNavigationTimings.begin(visible ? "toggle.show" : "toggle.hide")
#if DEBUG
        let probe = SidebarToggleSlideProbe.begin(visible: visible, window: window, animator: self)
#endif
        execute(machine.request(visible: visible, width: Double(layout.width), now: CACurrentMediaTime()), in: window)
        drainQueuedRequests(in: window)
        syncPendingVisibility()
#if DEBUG
        probe?.keypressDidFinish()
#endif
        SidebarNavigationTimings.end(visible ? "toggle.show" : "toggle.hide")
        return true
    }

    /// Presses that arrived while effects ran (the atomic commit spins the
    /// run loop once), in order.
    private func drainQueuedRequests(in window: NSWindow) {
        while !queuedRequests.isEmpty {
            let next = queuedRequests.removeFirst()
            guard let layout else { continue }
            execute(machine.request(visible: next, width: Double(layout.width), now: CACurrentMediaTime()), in: window)
        }
    }

    private func execute(_ effects: [SidebarToggleSlideMachine.Effect], in window: NSWindow) {
        isExecuting = true
        defer { isExecuting = false }
        var index = effects.startIndex
        while index < effects.endIndex {
            switch effects[index] {
            case .commitHiddenLayout:
                // The hidden layout and the slide's first pose land in one
                // frame: the terminal takes its full width under a content
                // root still offset by the sidebar width.
                let next = effects.index(after: index)
                let slide: SidebarToggleSlideMachine.Slide?
                if next < effects.endIndex, case let .animate(nextSlide) = effects[next] {
                    slide = nextSlide
                    index = next
                } else {
                    slide = nil
                }
                pendingDocked = SidebarSlideStart.dockedLayout(in: window)
                commitAtomically(in: window) {
                    layout?.docksSidebar = false
                    dockedLayoutWillCommit(false)
                } layers: {
                    if let slide { addSlideAnimation(slide, in: window) }
                }
                pendingDocked = nil
                if let slide { machine.slideDidStart(generation: slide.generation, at: CACurrentMediaTime()) }
            case let .animate(slide):
                CATransaction.begin()
                if slide.landsVisible { layout?.dockedPane?.setRowsOnScreen(true) }
                addSlideAnimation(slide, in: window)
                CATransaction.commit()
                CATransaction.flush()
                machine.slideDidStart(generation: slide.generation, at: CACurrentMediaTime())
            case .commitShownLayout:
                commitAtomically(in: window) {
                    layout?.docksSidebar = true
                    dockedLayoutWillCommit(true)
                    commitVisibility(true)
                } layers: {
                    removeSlideAnimations()
                }
            case .finishHide:
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layout?.dockedPane?.setRowsOnScreen(false)
                removeSlideAnimations()
                CATransaction.commit()
                // ContentView hears about the hide once the motion is over;
                // its body pass, the peek panel mount and the focus handoff
                // run on a frame where nothing moves.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.machine.slide == nil, !self.machine.target else { return }
                    self.commitVisibility(false)
                    self.syncPendingVisibility()
                }
            }
            index = effects.index(after: index)
        }
    }

    /// The divider drag's recipe (`SidebarDividerTrackingView`): with the
    /// interactive geometry resize held, mutate, let SwiftUI and Core
    /// Animation commit inside this event, then lay out, display and flush.
    /// The layout change, the portal's terminal frames and the layer change
    /// reach the screen in one frame, and the terminal resizes once.
    private func commitAtomically(in window: NSWindow, _ mutate: () -> Void, layers: () -> Void) {
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize(owner: self, in: window)
#if DEBUG
        let before = SidebarToggleSlideProbe.terminalFrameX(in: window)
#endif
        // One explicit transaction around everything: SwiftUI applies the
        // new layout (and the portal moves the terminals) inside the run loop
        // pass, but nothing reaches the screen until the layer change is in
        // too. Otherwise the content shows one frame at the wrong offset.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mutate()
        RunLoop.current.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.001))
        window.contentView?.layoutSubtreeIfNeeded()
#if DEBUG
        let after = SidebarToggleSlideProbe.terminalFrameX(in: window)
        let container = SidebarToggleSlideProbe.paneContainerX(in: window)
#endif
        // The portal follows SwiftUI's anchors on its own queue; move the
        // terminals now so they land with the layout.
        TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(window)]?
            .synchronizeAllEntriesFromExternalGeometryChange()
        layers()
        window.displayIfNeeded()
        CATransaction.commit()
        CATransaction.flush()
        TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: self)
#if DEBUG
        SidebarNavigationTimings.record("toggle.commit terminalX before=\(before) afterLayout=\(after) paneContainerX=\(container) afterFlush=\(SidebarToggleSlideProbe.terminalFrameX(in: window))")
#endif
    }

    private func addSlideAnimation(_ slide: SidebarToggleSlideMachine.Slide, in window: NSWindow) {
        // A visibility commit during the atomic commit's run loop pass can
        // drop the slide this was for; a session built for it would never land.
        guard machine.slide?.generation == slide.generation else { return }
        if session == nil, let views = Self.slidingViews(in: window), let layout {
            let start = captureStart(in: window, docked: pendingDocked)
            pendingDocked = nil
            let panes = SidebarSlideStart.isRigid ? nil : paneLayouts(for: start, reference: views[0], width: layout.width, window: window)
            session = SidebarToggleSlideSession(
                views: views,
                trailingStillWidth: trailingStillWidth(),
                titleGlide: layout.titlebarTitle?.glide(sidebarWidth: layout.width),
                tabRow: start.tabRow,
                chrome: start.chrome,
                panes: panes
            )
            watchLayout(in: window)
        }
        guard let session, !session.movingLayers.isEmpty else {
            // Nothing to move: land now, so the press still takes effect.
            // Called mid-execute, so the landing runs on the next turn.
            land(generation: slide.generation)
            return
        }
        let distance = slide.to - slide.from
        let velocity = distance == 0 ? 0 : slide.velocity / distance
        for (index, layer) in session.movingLayers.enumerated() {
            let animation = slideSpring(from: slide.from, to: slide.to, velocity: velocity, duration: slide.duration)
            if index == 0 {
                animation.delegate = SlideLandingDelegate { [weak self] in
                    self?.land(generation: slide.generation)
                }
            }
            layer.add(animation, forKey: Self.animationKey)
        }
        // The masks run the same spring backwards, so their edge stays put on
        // screen while the content under them moves.
        for mask in session.masks {
            let animation = slideSpring(from: -slide.from, to: -slide.to, velocity: velocity, duration: slide.duration)
            mask.add(animation, forKey: Self.animationKey)
        }
        // Chrome that rests elsewhere in the two layouts glides on top of the
        // content root's motion, by the same spring scaled (`SidebarSlideGlide`).
        for glide in session.glides {
            let animation = slideSpring(from: glide.base + slide.from * glide.factor, to: glide.base + slide.to * glide.factor, velocity: velocity, duration: slide.duration, keyPath: glide.keyPath)
            glide.layer.add(animation, forKey: Self.animationKey)
        }
    }

    private func captureStart(in window: NSWindow, docked: SidebarSlidePaneLayout?) -> SidebarSlideStart {
        SidebarSlideStart.capture(in: window, docked: docked, inset: tabBarInsetDelta(), sidebarWidth: layout?.width ?? 0, buttonCount: splitButtonCount())
    }

    /// The hidden layout is on screen now; the docked one was measured at a
    /// hide's press, seen at the last hide over this same hidden layout, or
    /// failing both, predicted.
    private func paneLayouts(for start: SidebarSlideStart, reference: NSView, width: CGFloat, window: NSWindow) -> SidebarToggleSlideSession.Panes {
        let hidden = start.hidden ?? SidebarSlidePaneLayout.measure(in: reference)
        let docked: SidebarSlidePaneLayout
        if let measured = start.docked {
            docked = measured
            paneLayouts = (hidden, measured, width)
        } else if let seen = paneLayouts, seen.width == width, seen.hidden.matches(hidden) {
            docked = seen.docked
        } else {
            docked = hidden.predictedDocked(in: reference, sidebarWidth: width)
        }
        return .init(hidden: hidden, docked: docked, portalViews: SidebarSlideStart.portalViews(in: window), sidebarWidth: width)
    }

    private func slideSpring(from: Double, to: Double, velocity: Double, duration: Double, keyPath: String = "transform.translation.x") -> CASpringAnimation {
        let spring = machine.spring
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.mass = 1
        animation.stiffness = spring.stiffness
        animation.damping = spring.damping
        animation.initialVelocity = velocity
        animation.duration = duration
        // No begin time: the spring starts when its transaction commits,
        // so a slow keypress commit delays the motion, never skips it.
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        animation.speed = Self.speed
        return animation
    }

    private func removeSlideAnimations() {
        session?.tearDown(animationKey: Self.animationKey)
        session = nil
        layoutObserver.map(NotificationCenter.default.removeObserver)
        layoutObserver = nil
    }

    /// The slide's motion is built for the pane layout at its start. A
    /// split, a close or a workspace switch mid-slide resizes split views;
    /// the slide then lands at once on the new layout instead of moving
    /// stale geometry.
    private func watchLayout(in window: NSWindow) {
        layoutObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main
        ) { [weak self, weak window] note in
            guard let splitView = note.object as? NSSplitView, let window, splitView.window === window,
                  SidebarSlidePaneLayout.splitView(splitView) != nil else { return }
            MainActor.assumeIsolated {
                guard let self, self.session != nil, let slide = self.machine.slide else { return }
#if DEBUG
                SidebarNavigationTimings.record("slide.layoutChanged split=\(ObjectIdentifier(splitView).hashValue) frame=\(splitView.frame) executing=\(self.isExecuting)")
#endif
                self.land(generation: slide.generation)
            }
        }
    }

    /// Idempotent: a stale or repeated landing does nothing.
    private func land(generation: Int) {
        if isExecuting {
            DispatchQueue.main.async { [weak self] in self?.land(generation: generation) }
            return
        }
        guard let window = window() else { return }
        let effects = machine.land(generation: generation)
        guard !effects.isEmpty else { return }
#if DEBUG
        let landingCPU = SidebarToggleSlideProbe.threadCPU()
#endif
        execute(effects, in: window)
#if DEBUG
        SidebarToggleSlideProbe.current?.didLand(cpu: SidebarToggleSlideProbe.threadCPU() - landingCPU)
        assert(session == nil)
        assert(layout?.docksSidebar == machine.docked)
#endif
        // After the asserts: a queued press may start the next slide.
        drainQueuedRequests(in: window)
        syncPendingVisibility()
    }

    private func commitVisibility(_ visible: Bool) {
        isCommittingVisibility = true
        sidebarState?.setVisible(visible)
        isCommittingVisibility = false
    }

    /// Someone else set the visibility (session restore, narrow-window
    /// collapse, the instant path): drop any slide and follow it.
    private func visibilityDidCommit(_ visible: Bool) {
        guard !isCommittingVisibility else { return }
        queuedRequests.removeAll()
        if session != nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            removeSlideAnimations()
            CATransaction.commit()
        }
        machine.reset(visible: visible)
        if layout?.docksSidebar != visible {
            layout?.docksSidebar = visible
        }
    }

    private func syncPendingVisibility() {
        guard let sidebarState else { return }
        let pending: Bool? = machine.target == sidebarState.isVisible ? nil : machine.target
        if sidebarState.pendingVisibility != pending {
            sidebarState.pendingVisibility = pending
        }
    }

    /// The views that move: the window content root (the sidebar column and
    /// the workspace card live in it) and the terminal and browser portal
    /// hosts stacked above it, which draw the terminals.
    private static func slidingViews(in window: NSWindow) -> [NSView]? {
        guard let portal = TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(window)],
              let reference = portal.installedReferenceView,
              let container = reference.superview else { return nil }
        var views: [NSView] = [reference]
        if portal.hostView.superview === container {
            views.append(portal.hostView)
        }
        views.append(contentsOf: container.subviews.filter { $0 is WindowBrowserHostView })
        return views.allSatisfy({ $0.layer != nil }) ? views : nil
    }

    /// DEBUG-only slow motion (`CMUX_SIDEBAR_SLIDE_SLOWDOWN=20`) for checking
    /// captured frames by eye.
    private static let speed: Float = {
#if DEBUG
        if let raw = ProcessInfo.processInfo.environment["CMUX_SIDEBAR_SLIDE_SLOWDOWN"],
           let slowdown = Float(raw), slowdown > 0 {
            return 1 / slowdown
        }
#endif
        return 1
    }()

#if DEBUG
    var debugWindow: NSWindow? { window() }
    var debugSidebarState: SidebarState? { sidebarState }
#endif
}

/// Lands the slide when its spring stops. Core Animation retains its
/// delegate; the closure holds the animator weakly.
///
/// Every stop lands, finished or not: a spring removed early (its layer
/// left the tree) must not strand the layout. A retargeted or torn-down
/// slide's generation is stale by then, so its landing does nothing.
private final class SlideLandingDelegate: NSObject, CAAnimationDelegate {
    private let onLand: @MainActor @Sendable () -> Void

    init(onLand: @escaping @MainActor @Sendable () -> Void) {
        self.onLand = onLand
    }

    func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        let onLand = onLand
        // Out of Core Animation's callout before touching layout.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onLand() }
        }
    }
}
