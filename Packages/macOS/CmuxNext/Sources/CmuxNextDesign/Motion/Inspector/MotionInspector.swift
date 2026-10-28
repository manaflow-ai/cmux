public import AppKit
public import Observation
public import CmuxNextDesignTokens
public import CmuxNextWakeups

/// The Motion Inspector: slows down, pauses, steps and lists cmux's animations so a person or an agent
/// can review them (Lawrence 2026-10-28: "a swift tool that helps us slow down, inspect, and review
/// animations properly"; plans/cmux-next/motion-inspector.md). One model, reached three ways: Debug >
/// Debug Windows > Motion Inspector (``MotionInspectorWindow``), the `debug.motion` socket actions
/// (``MotionDebug``) and `scripts/cmux-next/motion.py`.
///
/// Slow motion applies one ``MotionTimeScale`` to every motion path at once, from the places each kind of
/// motion keeps its time:
/// - Core Animation (every render-server animation, the gate's, Ghostty-free colors, ungated ones too):
///   each window's root layer time base (``MotionTimebase``), so running animations slow from where they
///   are, pause, and step one display frame forward or back.
/// - CPU springs (``MotionClock``: pane layout, tab autoscroll): each frame's `dt` times the rate; while
///   paused the clock parks with no display link, and a step forward runs one frame.
/// - Motion that cannot pause (AppKit `animator()` groups AppKit steps on the main thread, gate SwiftUI
///   animations, the terminal's color blend, web pages): lengthened by ``MotionTimeScale/startScale``
///   when it starts.
///
/// The filter leaves categories out (their changes apply in one frame), so only the kinds under review move.
///
/// The composition root makes the app's one inspector (and its window) and injects it; while it inspects it
/// registers itself on the ``DesignSettings`` it was given (``DesignSettings/activeMotionInspector``), the
/// object every gate already reads, so the gate's hooks reach it with no global of its own. A test makes its
/// own over its own settings, or over `DesignSettings.shared` to see the gates' animations.
///
/// Off, it costs nothing per frame: every hook is one read of the settings' active inspector (nil), no frame
/// client runs, and nothing observes it. On, its own main-thread time is measured and shown (``overhead``).
@Observable
public final class MotionInspector {
    // MARK: Hot-path state (read by the gate's hooks, never observed)

    /// The inspector the gates report to: `DesignSettings.shared`'s while one inspects, else nil.
    static var active: MotionInspector? { DesignSettings.shared.activeMotionInspector }
    /// An inspector inspects the gates now.
    public static var isActive: Bool { active != nil }
    /// How much an animation that cannot pause is lengthened when it starts (1 while not inspecting).
    public static var startScale: Double { active?.startScale ?? 1 }
    /// Animation seconds per wall second for ``MotionClock`` springs (1 while not inspecting, 0 paused).
    public static var clockRate: Double { active?.clockRate ?? 1 }
    /// This inspector's ``MotionInspector/startScale`` (1 until it slows motion).
    @ObservationIgnored public private(set) var startScale: Double = 1
    /// This inspector's ``MotionInspector/clockRate`` (1 until it slows motion).
    @ObservationIgnored public private(set) var clockRate: Double = 1
    /// The gate entry point running now (set by ``within(_:_:_:_:)``).
    @ObservationIgnored var site: CallSite?
    /// Perceived durations of the springs seen (it simulates), by tuning.
    @ObservationIgnored var perceivedCache: [SpringKey: Double] = [:]

    // MARK: Observed state

    /// Whether this inspector inspects (``start()`` to ``stop()``).
    public private(set) var isInspecting = false
    /// The time scale every motion path plays at.
    public private(set) var timeScale: MotionTimeScale = .x1
    /// The categories the filter keeps; nil keeps every one.
    public private(set) var keptCategories: Set<MotionCategory>?
    /// The named kind the filter shows (``FilterKind``), when one was chosen: only its records list.
    public private(set) var filterKind: FilterKind?
    /// Animations seen since the inspection started: every running one, then the newest ended ones.
    public internal(set) var records: [MotionInspectorRecord] = []
    /// What the last ``scan()`` found that no gate helper made.
    public internal(set) var findings: [MotionInspectorFinding] = []
    /// The inspector's own main-thread cost. Not observed: each record change already redraws the window,
    /// and the window adds its own draw time here.
    @ObservationIgnored public internal(set) var overhead = MotionInspectorOverhead()

    /// Ended records kept after the running ones.
    public static let endedKept = 120

    // MARK: Dependencies

    @ObservationIgnored let now: @MainActor () -> CFTimeInterval
    @ObservationIgnored let windows: @MainActor () -> [NSWindow]
    @ObservationIgnored let design: DesignSettings
    @ObservationIgnored private let scheduler: @MainActor () -> FrameScheduler
    @ObservationIgnored private let clocks: @MainActor () -> [MotionClock]

    // MARK: Private state

    /// Each retimed root layer and the time base it had before the inspector touched it.
    @ObservationIgnored private var originals: [ObjectIdentifier: (layer: WeakLayer, base: MotionTimebase)] = [:]
    @ObservationIgnored private var motionBase: Double = 0
    @ObservationIgnored private var wallBase: CFTimeInterval = 0
    @ObservationIgnored var nextID: UInt64 = 0
    /// Wall time of the last record added (coalescing one turn's starts, ``add(kind:property:from:to:curve:runs:ownerType:start:end:)``).
    @ObservationIgnored var lastAddWall: CFTimeInterval = -.infinity
    /// Wall time of the last pass over the windows for ones that appeared while slowed.
    @ObservationIgnored private var lastWindowPass: CFTimeInterval = -.infinity
    // frame-client: the inspector's count of each running animation's frames and drops; active only while one runs
    @ObservationIgnored private lazy var frames = FrameClient(owner: "MotionInspector", rate: .motion, scheduler: scheduler) { [weak self] tick in
        self?.tick(tick) ?? false
    }

    /// - Parameters:
    ///   - now: Media time (`CACurrentMediaTime`); a test passes its own clock.
    ///   - windows: The windows whose root layers the time scale retimes and the scan reads.
    ///   - design: The settings the filter and the web time scale go through (``DesignSettings/motionInspection``)
    ///     and the inspector registers on while it inspects; the gates report to `DesignSettings.shared`'s.
    ///   - scheduler: The frames the inspector counts on while an animation runs.
    ///   - clocks: The CPU-spring clocks a pause parks and a step moves; nil: every window's and the app's.
    public init(now: @escaping @MainActor () -> CFTimeInterval = { CACurrentMediaTime() },
                windows: @escaping @MainActor () -> [NSWindow] = { NSApp?.windows ?? [] },
                design: DesignSettings, scheduler: @escaping @MainActor () -> FrameScheduler = { .app },
                clocks: (@MainActor () -> [MotionClock])? = nil) {
        self.now = now
        self.windows = windows
        self.design = design
        self.scheduler = scheduler
        self.clocks = clocks ?? { MotionClock.existing(in: windows()) }
    }

    // MARK: Lifecycle

    /// Starts inspecting: the hooks record each animation that starts from now on.
    public func start() {
        guard !isInspecting else { return }
        design.activeMotionInspector?.stop()
        isInspecting = true
        records = []
        findings = []
        overhead = MotionInspectorOverhead()
        motionBase = 0
        wallBase = now()
        design.activeMotionInspector = self
        syncRates()
    }

    /// Stops inspecting: every root layer gets its own time base back, parked clocks run again, the filter
    /// and the time scale go, and running records end. Nothing of the inspector runs after this.
    public func stop() {
        guard isInspecting else { return }
        let wasPaused = timeScale == .paused
        let end = motionNow
        for (layer, base) in originals.values {
            if let layer = layer.value { base.apply(to: layer) }
        }
        originals = [:]
        frames.deactivate()
        timeScale = .x1
        keptCategories = nil
        filterKind = nil
        design.motionInspection = .off
        if design.activeMotionInspector === self { design.activeMotionInspector = nil }
        syncRates()
        if wasPaused { resumeClocks() }
        var ended = records
        for index in ended.indices where ended[index].ended == nil { ended[index].ended = end }
        records = ended
        isInspecting = false
    }

    // MARK: Time scale

    /// Animation seconds since the inspection started: runs at the time scale's rate, stands still while paused,
    /// and moves by each step.
    public var motionNow: Double {
        motionBase + (now() - wallBase) * timeScale.rate
    }

    /// Plays every motion path at `scale` (starting the inspection when it is not running). Running Core
    /// Animation animations slow or pause from where they are; leaving pause resumes parked clocks.
    public func setTimeScale(_ scale: MotionTimeScale) {
        if !isInspecting { start() }
        guard scale != timeScale else { return }
        let wasPaused = timeScale == .paused
        motionBase = motionNow
        wallBase = now()
        timeScale = scale
        design.motionInspection.timeScale = scale
        syncRates()
        retimeWindows()
        if wasPaused, scale != .paused { resumeClocks() }
        if scale != .paused, records.contains(where: \.isRunning) { frames.activate() }
    }

    /// Keeps only `kept` categories moving (nil: every category). The rest apply in one frame, as with
    /// their `ui.animations.<category>` off, in memory only.
    public func setFilter(keeping kept: Set<MotionCategory>?) {
        if !isInspecting { start() }
        filterKind = nil
        keptCategories = kept.flatMap { $0.count == MotionCategory.allCases.count ? nil : $0 }
        design.motionInspection.excludedCategories = MotionInspection.excluded(keeping: keptCategories)
    }

    /// A named kind of animation to review alone: its categories keep moving (the others apply in one frame),
    /// and the list shows only its records (by call site). `sidebarRows` is a sidebar workspace row opening,
    /// closing or moving (Cmd-N, Cmd-W, a reorder); `tabStrip` a tab opening, closing or moving.
    public enum FilterKind: String, Sendable, CaseIterable {
        case sidebarRows
        case tabStrip
        case panes
        case overlays
        case feedback

        /// The categories that keep moving.
        public var categories: Set<MotionCategory> {
            switch self {
            case .sidebarRows: [.sidebar]
            case .tabStrip: [.tabs]
            case .panes: [.panes]
            case .overlays: [.overlays, .hoverCards]
            case .feedback: [.feedback]
            }
        }

        /// The call-site files whose records it lists (nil: every record of its categories).
        public var sites: [String]? {
            switch self {
            case .sidebarRows: ["CmuxNextSidebar/Views/SidebarDragSpring.swift", "CmuxNextSidebar/Views/SidebarRowMotion.swift",
                                "CmuxNextSidebar/Views/SidebarListView", "CmuxNextSidebar/Logic/SidebarLayout+Viewport.swift"]
            case .tabStrip: ["CmuxNextTabs/"]
            default: nil
            }
        }

        /// Whether `record` is one of this kind's.
        public func matches(_ record: MotionInspectorRecord) -> Bool {
            if let sites { return record.site.map { site in sites.contains { site.hasPrefix($0) } } ?? false }
            return record.category.map(categories.contains) ?? false
        }
    }

    /// Reviews `kind` alone: its categories keep moving, the list shows its records.
    public func setFilter(kind: FilterKind) {
        setFilter(keeping: kind.categories)
        filterKind = kind
    }

    /// The records the filter shows: every one, or the chosen kind's.
    public var shownRecords: [MotionInspectorRecord] {
        guard let filterKind else { return records }
        return records.filter(filterKind.matches)
    }

    /// Seconds of one display frame: the first window's screen's refresh, 60 Hz without one.
    public var frameInterval: Double {
        let fps = windows().lazy.compactMap { $0.screen?.maximumFramesPerSecond }.first ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        return 1 / Double(max(fps, 1))
    }

    /// What one ``step(frames:)`` moved.
    public struct Step: Sendable, Equatable {
        /// Seconds of animation time every Core Animation animation moved (negative: back).
        public var seconds: Double
        /// Root layers retimed.
        public var layers: Int
        /// CPU-spring frames run (a step back runs none: a spring's past is not kept).
        public var clockFrames: Int
    }

    /// Pauses (when not paused) and moves every animation `frames` display frames (negative: back).
    /// Core Animation animations step both ways; CPU springs (``MotionClock``) step forward only.
    @discardableResult
    public func step(frames count: Int) -> Step {
        if timeScale != .paused { setTimeScale(.paused) }
        let interval = frameInterval
        let seconds = Double(count) * interval
        var layers = 0
        for (layer, _) in originals.values {
            guard let layer = layer.value else { continue }
            MotionTimebase(of: layer).stepped(by: seconds).apply(to: layer)
            layers += 1
        }
        var clockFrames = 0
        if count > 0 {
            for clock in clocks() where clock.isParkedByInspector {
                for _ in 0..<count where clock.inspectorStep(seconds: interval) { clockFrames += 1 }
            }
        }
        motionBase += seconds
        countSteppedFrames(abs(count))
        return Step(seconds: seconds, layers: layers, clockFrames: clockFrames)
    }

    // MARK: Windows

    /// The layer whose time base every animation of `window` runs on: the frame view's, else the content view's.
    public static func rootLayer(of window: NSWindow) -> CALayer? {
        window.contentView?.superview?.layer ?? window.contentView?.layer
    }

    /// Retimes every window's root layer to the time scale: from the time it shows now (no jump), or back
    /// to its own time base at 1x.
    private func retimeWindows() {
        for window in windows() { retime(window) }
        originals = originals.filter { $0.value.layer.value != nil }
    }

    private func retime(_ window: NSWindow) {
        guard let layer = Self.rootLayer(of: window) else { return }
        let id = ObjectIdentifier(layer)
        if timeScale == .x1 {
            if let saved = originals.removeValue(forKey: id) { saved.base.apply(to: layer) }
            return
        }
        if originals[id] == nil { originals[id] = (WeakLayer(layer), MotionTimebase(of: layer)) }
        let mediaNow = now()
        let parent = layer.superlayer?.convertTime(mediaNow, from: nil) ?? mediaNow
        MotionTimebase(of: layer).retimed(rate: timeScale.rate, atParent: parent).apply(to: layer)
    }

    /// While slowed, a window that appeared since the last pass (a popup, a hover card, a new window) joins the
    /// time scale. Called as each gate animation starts, in its turn before its commit, at most once per turn: the
    /// first animation of a new popup already plays slowed. One dictionary read per window; its time counts in
    /// ``overhead``. An ungated animation in a window no gate animation has started in yet plays at real time.
    func retimeNewWindows() {
        guard timeScale != .x1 else { return }
        let wall = now()
        guard wall - lastWindowPass > 0.001 else { return }
        lastWindowPass = wall
        let began = CACurrentMediaTime()
        for window in windows() {
            guard let layer = Self.rootLayer(of: window), originals[ObjectIdentifier(layer)] == nil else { continue }
            retime(window)
        }
        overhead.addToLastFrame((CACurrentMediaTime() - began) * 1000)
    }

    // MARK: Clocks and statics

    private func resumeClocks() {
        for clock in clocks() { clock.resumeFromInspector() }
    }

    private func syncRates() {
        startScale = isInspecting ? timeScale.startScale : 1
        clockRate = isInspecting ? timeScale.rate : 1
    }

    // MARK: Frames

    /// Starts counting frames for the running records (a record started).
    func runningChanged() {
        guard timeScale != .paused, records.contains(where: \.isRunning) else { return }
        frames.activate()
    }

    /// One display frame: each running record counts it (and the refreshes the main thread missed before
    /// it), and a record whose curve ran out ends. Returns false once nothing runs.
    /// ``tick(_:)`` for a test's frame.
    func tickForTesting(_ tick: FrameTick) -> Bool { self.tick(tick) }

    private func tick(_ tick: FrameTick) -> Bool {
        let began = CACurrentMediaTime()
        guard timeScale != .paused else { return false }
        let at = motionNow
        let interval = tick.refreshInterval ?? FrameTick.defaultRefreshInterval
        let missed = max(0, Int((tick.rawElapsed / interval).rounded()) - 1)
        var updated = records
        var running = false
        for index in updated.indices where updated[index].ended == nil {
            updated[index].frames += 1
            updated[index].droppedFrames += missed
            if let end = updated[index].expectedEnd, at >= end {
                updated[index].ended = end
            } else {
                running = true
            }
        }
        records = Self.pruned(updated)
        overhead.addFrame((CACurrentMediaTime() - began) * 1000)
        return running
    }

    private func countSteppedFrames(_ count: Int) {
        guard count > 0 else { return }
        let at = motionNow
        var updated = records
        for index in updated.indices where updated[index].ended == nil {
            updated[index].frames += count
            if let end = updated[index].expectedEnd, at >= end { updated[index].ended = end }
        }
        records = Self.pruned(updated)
    }

    /// Every running record, then the newest ``endedKept`` ended ones, in start order.
    static func pruned(_ records: [MotionInspectorRecord]) -> [MotionInspectorRecord] {
        let ended = records.filter { !$0.isRunning }
        guard ended.count > endedKept else { return records }
        let dropped = Set(ended.prefix(ended.count - endedKept).map(\.id))
        return records.filter { !dropped.contains($0.id) }
    }
}

/// A root layer the inspector retimed, held weakly (a closed window frees it).
struct WeakLayer {
    weak var value: CALayer?
    init(_ value: CALayer) { self.value = value }
}
