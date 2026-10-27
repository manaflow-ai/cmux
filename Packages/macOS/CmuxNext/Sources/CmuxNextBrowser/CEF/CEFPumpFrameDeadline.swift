import CmuxNextInputCore
public import CmuxNextWakeups
public import Foundation

/// What the in-process pump's frame-deadline slices (``CEFPumpFrameDeadline``, feature
/// `cefPumpFrameDeadline`) read from the app: the frame clock, the main thread's measured commit, the
/// person's input turn and the app's one pending-input source. Nil keeps every pass at the fork's
/// static slice.
///
/// ```swift
/// // AppServices: the engine's pump slices to the main frame scheduler's deadline.
/// CEFEngine(source: source, stores: stores, signInCallbacks: callbacks, input: inputTap)
///     .slicingPumpToFrames(of: features.isEnabled(.cefPumpFrameDeadline) ? mainWork : nil)
/// ```
public struct CEFPumpFrameSeams {
    /// When the frame being made is shown, in seconds since boot; nil while no frame is made.
    public let frameTarget: @MainActor () -> TimeInterval?
    /// The frame clock's refresh interval in seconds.
    public let refreshInterval: @MainActor () -> TimeInterval
    /// The main thread's measured commit in seconds (layout, display and the Core Animation commit);
    /// nil before any was measured.
    public let commitEstimate: @MainActor () -> TimeInterval?
    /// A person's input turn is open: a discrete input's dispatch runs, or its frame has not rendered.
    public let inputTurnOpen: @MainActor () -> Bool
    /// Whether a person's input waits for the main thread.
    public let pending: any InputPendingSource

    public init(frameTarget: @escaping @MainActor () -> TimeInterval?, refreshInterval: @escaping @MainActor () -> TimeInterval,
                commitEstimate: @escaping @MainActor () -> TimeInterval?, inputTurnOpen: @escaping @MainActor () -> Bool,
                pending: any InputPendingSource) {
        self.frameTarget = frameTarget
        self.refreshInterval = refreshInterval
        self.commitEstimate = commitEstimate
        self.inputTurnOpen = inputTurnOpen
        self.pending = pending
    }

    /// The app's: its frame scheduler's target and refresh, its budget's commit estimate
    /// (``MainCommitMeter``, task 015), input response and pending-input source.
    public init(mainWork: MainWorkScheduler) {
        let frames = mainWork.frames
        let budget = mainWork.budget
        self.init(frameTarget: { [weak frames] in frames?.frameTarget },
                  refreshInterval: { [weak frames] in frames?.refreshPeriod ?? 1.0 / 60 },
                  commitEstimate: { [weak budget] in budget?.commitEstimateNanos.map { TimeInterval($0) / 1_000_000_000 } },
                  inputTurnOpen: { [weak budget] in budget.map { $0.isDiscreteDispatchOpen || $0.isInputResponseOpen } ?? false },
                  pending: budget.pendingInput)
    }
}

/// The in-process pump's slices on the main thread's frame deadline (plans/cmux-next/chrome-parity/
/// p03-rendering.md, task 116; ``CEFPumpSchedule/FrameSlicer`` decides). Each due pass gets the time
/// left before the frame's commit through the fork's per-call slice (`cmux_shim_set_pump_time_slice`),
/// waits for the next frame when less than 1 ms is left, and waits for a person's input turn; a fork
/// without the call keeps the static `--cmux-pump-time-slice-us` for every pass.
///
/// Until the F2 program moves the pump off the main thread (PL-cefhost), this is how a Chromium pass
/// keeps out of the app's frames. In host mode the app has no pump and makes none.
///
/// ```swift
/// let deadline = CEFPumpFrameDeadline(seams: seams, cap: CEFPumpSchedule.timeSlice(forkAPI: forkAPI),
///                                     setSlice: perCall ? { _ = shim.setPumpTimeSlice($0) } : nil)
/// pump.setFrameDeadline(deadline)
/// ```
final class CEFPumpFrameDeadline {
    /// What the pump does with a due pass.
    enum Admission: Equatable {
        /// Run it; `slice` in microseconds, nil: the fork's static switch.
        case run(slice: Int64?)
        /// Hold it until `until` (the timer fires then, exactly), then decide again.
        case hold(until: TimeInterval)
    }

    /// Due passes held for the next frame (``CEFPumpStats/frameDeadlineWaits``).
    private(set) var frameWaits = 0
    /// Due passes held for a person's input (``CEFPumpStats/frameInputHolds``).
    private(set) var inputHolds = 0
    private let seams: CEFPumpFrameSeams
    private var slicer: CEFPumpSchedule.FrameSlicer
    /// Gives the next pass its slice; nil: the fork has no per-call slice.
    private let setSlice: ((Int64) -> Void)?
    private let pageHasKeyboard: @MainActor () -> Bool
    private let clock: () -> TimeInterval
    /// Follows the end of each input's dispatch for input to a Chromium page.
    private var subscription: InputSubscription?
    private var pageInput = CEFPumpSchedule.RecentPageInput()

    /// - Parameters:
    ///   - seams: The frame clock, the measured commit and the person's input.
    ///   - cap: The longest slice: the loaded fork's static one (``CEFPumpSchedule/timeSlice(forkAPI:)``).
    ///   - setSlice: Gives the next pass its slice in microseconds; nil when the fork lacks the call.
    ///   - pageHasKeyboard: Whether a Chromium view has the keyboard (its keys are Chromium's input).
    ///   - dispatches: The end of each input's dispatch and where it went (nil: none followed).
    ///   - clock: The pump's clock, in seconds since boot.
    init(seams: CEFPumpFrameSeams, cap: TimeInterval, setSlice: ((Int64) -> Void)?,
         pageHasKeyboard: @escaping @MainActor () -> Bool = { false }, dispatches: (any CEFPumpInputDispatches)? = nil,
         clock: @escaping () -> TimeInterval = CEFMessagePump.uptime) {
        self.seams = seams
        self.setSlice = setSlice
        self.pageHasKeyboard = pageHasKeyboard
        self.clock = clock
        slicer = CEFPumpSchedule.FrameSlicer(cap: cap, perCall: setSlice != nil)
        subscription = dispatches?.observeDispatchEnd { [weak self] target in self?.dispatchEnded(target) }
    }

    /// The fork takes a slice per pass.
    var perCall: Bool { slicer.perCall }

    /// What the pass due at `now` does. `servesPage`: the pump knows the pass serves a Chromium page's
    /// input (the input policy's pass after a page dispatch).
    func decide(now: TimeInterval, servesPage: Bool) -> CEFPumpSchedule.SliceDecision {
        let refresh = refreshInterval()
        let frame = Self.frame(target: seams.frameTarget(), refresh: refresh, commit: seams.commitEstimate())
        let page = servesPage || pageInput.isRecent(at: now, refresh: refresh) || pageHasKeyboard()
        let pending = seams.pending
        return slicer.decide(now: now, frame: frame, refresh: refresh, inputTurn: seams.inputTurnOpen(), pageInput: page,
                             inputPending: { pending.hasPendingInput(uptime: now) })
    }

    /// What the pump does with the pass due at `now` (``decide(now:servesPage:)``), counted.
    func admit(now: TimeInterval, servesPage: Bool) -> Admission {
        switch decide(now: now, servesPage: servesPage) {
        case .run(let microseconds):
            return .run(slice: microseconds)
        case .waitForFrame(let until):
            frameWaits += 1
            return .hold(until: until)
        case .holdForInput(let until):
            inputHolds += 1
            return .hold(until: until)
        }
    }

    /// Starts the hold counters over (`debug.input` action `reset`).
    func resetCounters() {
        frameWaits = 0
        inputHolds = 0
    }

    /// A pass begins with `microseconds` as its slice (nil: the static switch's); the fork takes it for
    /// that pass only.
    func passBegins(slice microseconds: Int64?) {
        pageInput.passBegan()
        if let microseconds { setSlice?(microseconds) }
    }

    /// A pass ended; `usedWholeSlice`: it ran its whole slice, so Chromium has work left.
    func passEnded(usedWholeSlice: Bool) {
        slicer.passEnded(usedWholeSlice: usedWholeSlice)
    }

    /// Stops following input (the pump stopped).
    func stop() {
        subscription?.cancel()
        subscription = nil
    }

    /// The frame being made, nil without a target or a measured commit.
    static func frame(target: TimeInterval?, refresh: TimeInterval, commit: TimeInterval?) -> CEFPumpSchedule.Frame? {
        guard let target, let commit else { return nil }
        return CEFPumpSchedule.Frame(target: target, refresh: refresh, commit: commit)
    }

    /// One refresh, 60 Hz when the frame clock reports none.
    private func refreshInterval() -> TimeInterval {
        let interval = seams.refreshInterval()
        return interval.isFinite && interval > 0 ? interval : 1.0 / 60
    }

    private func dispatchEnded(_ target: InputTarget) {
        guard target == .chromiumPage else { return }
        pageInput.dispatched(at: clock())
    }
}

extension CEFEngine {
    /// The in-process pump slices each pass to `work`'s frame deadline (``CEFPumpFrameDeadline``, feature
    /// `cefPumpFrameDeadline`); nil keeps the fork's static slice. Read when Chromium starts.
    public func slicingPumpToFrames(of work: MainWorkScheduler?) -> CEFEngine {
        CEFRuntime.shared.pumpFrames = work.map { CEFPumpFrameSeams(mainWork: $0) }
        return self
    }
}
