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
    private var isPeekPresenting: () -> Bool = { false }
    private var machine = SidebarToggleSlideMachine(docked: true)
    /// Layers carrying the running slide, captured when it starts and kept
    /// for every retarget until it lands.
    private var slideLayers: [CALayer] = []
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
        isPeekPresenting: @escaping () -> Bool
    ) {
        self.sidebarState = sidebarState
        self.layout = layout
        self.window = window
        self.canSlide = canSlide
        self.isPeekPresenting = isPeekPresenting
        machine = SidebarToggleSlideMachine(docked: sidebarState.isVisible)
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
        let isSliding = machine.slide != nil
        guard sidebarState.presentationMode == .docked,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              canSlide(),
              let window = window(),
              isSliding || Self.slidingLayers(in: window) != nil else {
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
        let width = Double(layout.width)
        execute(machine.request(visible: visible, width: width, now: CACurrentMediaTime()), in: window)
        while !queuedRequests.isEmpty {
            let next = queuedRequests.removeFirst()
            execute(machine.request(visible: next, width: width, now: CACurrentMediaTime()), in: window)
        }
        syncPendingVisibility()
#if DEBUG
        probe?.keypressDidFinish()
#endif
        SidebarNavigationTimings.end(visible ? "toggle.show" : "toggle.hide")
        return true
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
                commitAtomically(in: window) {
                    layout?.docksSidebar = false
                } layers: {
                    if let slide { addSlideAnimation(slide, in: window) }
                }
                if let slide { machine.slideDidStart(generation: slide.generation, at: CACurrentMediaTime()) }
            case let .animate(slide):
                CATransaction.begin()
                addSlideAnimation(slide, in: window)
                CATransaction.commit()
                CATransaction.flush()
                machine.slideDidStart(generation: slide.generation, at: CACurrentMediaTime())
            case .commitShownLayout:
                commitAtomically(in: window) {
                    layout?.docksSidebar = true
                    commitVisibility(true)
                } layers: {
                    removeSlideAnimations()
                }
            case .finishHide:
                CATransaction.begin()
                CATransaction.setDisableActions(true)
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
        mutate()
        layers()
        RunLoop.current.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.001))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: self)
    }

    private func addSlideAnimation(_ slide: SidebarToggleSlideMachine.Slide, in window: NSWindow) {
        if slideLayers.isEmpty {
            slideLayers = Self.slidingLayers(in: window) ?? []
        }
        let spring = machine.spring
        let distance = slide.to - slide.from
        for (index, layer) in slideLayers.enumerated() {
            let animation = CASpringAnimation(keyPath: "transform.translation.x")
            animation.fromValue = slide.from
            animation.toValue = slide.to
            animation.mass = 1
            animation.stiffness = spring.stiffness
            animation.damping = spring.damping
            animation.initialVelocity = distance == 0 ? 0 : slide.velocity / distance
            animation.duration = slide.duration
            // No begin time: the spring starts when its transaction commits,
            // so a slow keypress commit delays the motion, never skips it.
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
            if index == 0 {
                animation.delegate = SlideLandingDelegate { [weak self] in
                    self?.land(generation: slide.generation)
                }
            }
            layer.add(animation, forKey: Self.animationKey)
        }
        // A missed delegate callback must not strand the layout: land anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + slide.duration + 0.1) { [weak self] in
            self?.land(generation: slide.generation)
        }
    }

    private func removeSlideAnimations() {
        for layer in slideLayers {
            layer.removeAnimation(forKey: Self.animationKey)
        }
        slideLayers = []
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
        syncPendingVisibility()
#if DEBUG
        SidebarToggleSlideProbe.current?.didLand(cpu: SidebarToggleSlideProbe.threadCPU() - landingCPU)
        assert(slideLayers.allSatisfy { $0.animation(forKey: Self.animationKey) == nil })
        assert(layout?.docksSidebar == machine.docked)
#endif
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
        if machine.slide != nil {
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

    /// The layers that move: the window content root (the sidebar column and
    /// the workspace card live in it) and the terminal and browser portal
    /// hosts stacked above it, which draw the terminals.
    private static func slidingLayers(in window: NSWindow) -> [CALayer]? {
        guard let portal = TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(window)],
              let reference = portal.installedReferenceView,
              let container = reference.superview else { return nil }
        var views: [NSView] = [reference]
        if portal.hostView.superview === container {
            views.append(portal.hostView)
        }
        views.append(contentsOf: container.subviews.filter { $0 is WindowBrowserHostView })
        let layers = views.compactMap(\.layer)
        return layers.count == views.count ? layers : nil
    }

#if DEBUG
    var debugWindow: NSWindow? { window() }
    var debugSidebarState: SidebarState? { sidebarState }
#endif
}

/// Lands the slide when its spring finishes. Core Animation retains its
/// delegate; the closure holds the animator weakly.
private final class SlideLandingDelegate: NSObject, CAAnimationDelegate {
    private let onLand: @MainActor @Sendable () -> Void

    init(onLand: @escaping @MainActor @Sendable () -> Void) {
        self.onLand = onLand
    }

    func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        guard finished else { return }
        let onLand = onLand
        // Out of Core Animation's callout before touching layout.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onLand() }
        }
    }
}

#if DEBUG
/// DEBUG-only numbers per press into `CMUX_NAV_TIMINGS_LOG`: main-thread CPU
/// of the keypress turn and of the landing, keypress to first frame, frame
/// intervals and main-thread CPU per frame while moving, and how many
/// visible sidebar rows had no title on the first frame of a show.
/// `notifyutil -p com.cmuxterm.debug.sidebar-toggle` presses the toggle in
/// the frontmost window, so this runs without driving the pointer.
@MainActor
final class SidebarToggleSlideProbe: NSObject {
    static weak var current: SidebarToggleSlideProbe?
    private static var live: SidebarToggleSlideProbe?

    private let name: String
    private let visible: Bool
    private weak var window: NSWindow?
    private let startWall = CACurrentMediaTime()
    private let startCPU = SidebarToggleSlideProbe.threadCPU()
    private var keypressCPU = 0.0
    private var landingCPU: Double?
    private var link: CADisplayLink?
    private var last: (wall: CFTimeInterval, cpu: Double)?
    private var firstFrameMs: Double?
    private var blankRows: Int?
    private var intervals: [Double] = []
    private var cpu: [Double] = []
    private var landedWall: CFTimeInterval?
    private var finished = false

    static func threadCPU() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
    }

    static func begin(visible: Bool, window: NSWindow, animator: SidebarToggleAnimator) -> SidebarToggleSlideProbe? {
        guard SidebarNavigationTimings.isEnabled, let view = window.contentView else { return nil }
        live?.finish()
        let probe = SidebarToggleSlideProbe(visible: visible, window: window)
        let link = view.displayLink(target: probe, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        probe.link = link
        live = probe
        current = probe
        return probe
    }

    private init(visible: Bool, window: NSWindow) {
        self.visible = visible
        self.name = visible ? "toggle.show" : "toggle.hide"
        self.window = window
        super.init()
    }

    func keypressDidFinish() {
        keypressCPU = Self.threadCPU() - startCPU
    }

    func didLand(cpu: Double) {
        landingCPU = cpu
        landedWall = CACurrentMediaTime()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = (wall: CACurrentMediaTime(), cpu: Self.threadCPU())
        if firstFrameMs == nil {
            firstFrameMs = (now.wall - startWall) * 1000
            if visible { blankRows = countBlankSidebarRows() }
        } else if let last {
            intervals.append((now.wall - last.wall) * 1000)
            cpu.append(now.cpu - last.cpu)
        }
        last = now
        if let landedWall, now.wall - landedWall > 0.15 { finish() }
        if now.wall - startWall > 2 { finish() }
    }

    private func countBlankSidebarRows() -> Int {
        guard let root = window?.contentView,
              let table = Self.sidebarTable(in: root) else { return -1 }
        let range = table.rows(in: table.visibleRect)
        var blank = 0
        for row in range.location..<(range.location + range.length) {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false),
                  NSStringFromClass(type(of: cell)).contains("WorkspaceRow") else { continue }
            if !Self.hasText(cell) { blank += 1 }
        }
        return blank
    }

    private static func sidebarTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView,
           NSStringFromClass(type(of: table)).contains("Sidebar")
            || NSStringFromClass(type(of: table.enclosingScrollView?.superview ?? table)).contains("SidebarWorkspaceTable") {
            return table
        }
        for subview in view.subviews {
            if let table = sidebarTable(in: subview) { return table }
        }
        return nil
    }

    private static func hasText(_ view: NSView) -> Bool {
        if let field = view as? NSTextField, !field.isHidden, !field.stringValue.isEmpty { return true }
        return view.subviews.contains { hasText($0) }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        link?.invalidate()
        link = nil
        if Self.live === self { Self.live = nil }
        let period = 1000.0 / Double(max(1, window?.screen?.maximumFramesPerSecond ?? 60))
        let dropped = intervals.reduce(0) { $0 + max(0, Int(($1 / period).rounded()) - 1) }
        let f = { (value: Double) in String(format: "%.2f", value) }
        let average = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)
        let moving = cpu.dropLast(landingCPU == nil ? 0 : 1)
        let cpuAverage = moving.isEmpty ? 0 : moving.reduce(0, +) / Double(moving.count)
        SidebarNavigationTimings.record(
            "nav.frames interaction=\(name) frames=\(intervals.count + 1) " +
            "keypressCpu=\(f(keypressCPU)) firstFrameMs=\(f(firstFrameMs ?? -1)) " +
            "landingCpu=\(f(landingCPU ?? -1)) landed=\(landingCPU == nil ? 0 : 1) " +
            "intervalAvg=\(f(average)) intervalMax=\(f(intervals.max() ?? 0)) dropped=\(dropped) period=\(f(period)) " +
            "movingCpuAvg=\(f(cpuAverage)) movingCpuMax=\(f(moving.max() ?? 0)) " +
            "blankRows=\(blankRows ?? -1)"
        )
        SidebarNavigationTimings.record(
            "nav.frames.detail interaction=\(name) intervals=" +
            intervals.map { String(format: "%.1f", $0) }.joined(separator: ",") +
            " cpu=" + cpu.map { String(format: "%.1f", $0) }.joined(separator: ",")
        )
    }

    private static func toggleIfFrontmost(_ animator: SidebarToggleAnimator) {
        let frontmost = NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.isVisible && $0.contentView != nil }
        guard let window = animator.debugWindow, window === frontmost else { return }
        animator.debugSidebarState?.toggle()
    }

    private static var triggerTargets: [ObjectIdentifier: () -> SidebarToggleAnimator?] = [:]

    static func installTrigger(for animator: SidebarToggleAnimator) {
        guard SidebarNavigationTimings.isEnabled else { return }
        triggerTargets[ObjectIdentifier(animator)] = { [weak animator] in animator }
        guard triggerTargets.count == 1 else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        for target in SidebarToggleSlideProbe.triggerTargets.values {
                            if let animator = target() { SidebarToggleSlideProbe.toggleIfFrontmost(animator) }
                        }
                    }
                }
            },
            "com.cmuxterm.debug.sidebar-toggle" as CFString,
            nil,
            .deliverImmediately
        )
    }
}
#endif
