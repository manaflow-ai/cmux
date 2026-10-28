public import AppKit

/// Keys typed while a window shows its launch picture (p08-startup-061). A key changes only this buffer in its turn
/// and asks the window to build its focused pane's slice in the next frame (``begin(window:shell:raise:)``); it never
/// builds the window, and no key waits for the window or its terminal view when it has a way to its terminal:
///
/// - A key for a terminal whose live view is not built (``hold(_:for:)``) goes at once to that terminal's input by its
///   id (``forward``): the daemon takes input for a terminal before any view of it is live, and queues it until its
///   first connection. One send per terminal is on its way at a time, and keys typed meanwhile go behind it, so none
///   overtakes another. Keys the send could not carry by id (``SendOutcome/keptForView(taken:)``: a remote session
///   that takes no input by id, a key with no input of its own, an input method's key) and every key behind them
///   wait for the terminal's live view, in order (``init(now:deliver:)``).
/// - Keys typed before the window can decide them go to the terminal its saved session restores focus to, by id (the
///   key router names it). Only when no such terminal can be named, or for a chord (it may be one of the window's
///   shortcuts), they wait whole (``holdUndecided(_:window:)``) and go through the key router again, in order, once
///   ``replay`` can decide them; a later key of the window queues behind them.
///
/// Each wait is a measured stage (``onWaitTotals``: per reason, its keys and how long, once at the phase's end). No key is dropped silently: keys
/// the daemon refuses, with every key behind them, are refused at once; keys still waiting for a view or for the
/// window when its picture leaves (its bound) are refused then. A refusal goes through ``refuse`` with the text the
/// window's refused keys typed, kept until the person is done with it (``forgetKept(window:)``).
///
/// Chrome keeps input for a page that cannot take it yet the same way: `RenderWidgetHostImpl` queues key events in
/// its `InputRouter` until the renderer is ready and delivers them in order
/// (content/browser/renderer_host/input/input_router_impl.cc); none is dropped for a slow first frame.
///
/// ```swift
/// keys.begin(window: "w1", shell: window) { pane in slices.raise(pane) }   // the picture frame (pane nil: not known)
/// keys.holdUndecided(event, window: "w1")                                  // no focus to send it to
/// keys.hold(event, for: .init(window: "w1", pane: "p", tab: "t"))          // a terminal still a picture: by id now
/// keys.retry()                                                             // a focus settle, the pane's first frame
/// keys.end(window: "w1")                                                   // the picture left: its bound
/// ```
@MainActor
public final class LaunchPictureKeys {
    /// The terminal a key was typed for.
    public nonisolated struct Target: Hashable, Sendable {
        /// The window's stable id (`WindowState.id`).
        public let window: String
        public let pane: String
        public let tab: String

        public init(window: String, pane: String, tab: String) {
            (self.window, self.pane, self.tab) = (window, pane, tab)
        }
    }

    /// How one ``Forward`` ended.
    public nonisolated enum SendOutcome: Sendable, Equatable {
        /// The daemon took every key (or may have: none is sent twice).
        case taken
        /// The daemon took the first `taken` keys; the rest can reach the terminal only through its live view.
        case keptForView(taken: Int)
        /// The daemon took the first `taken` keys and refused the rest, for `reason`.
        case refused(taken: Int, reason: String?)
        /// The daemon took the first `taken` keys; the reply for the next missed its deadline, so it may have
        /// arrived: it is never sent again, and it and the rest are refused with their text kept.
        case mayNotHaveArrived(taken: Int, reason: String?)
    }

    /// Why keys wait (``onWaitTotals``), as a launch stage name.
    public nonisolated enum WaitReason: String, Sendable, CaseIterable {
        /// No destination exists until the window decides focus.
        case undecided
        /// The terminal's daemon is not connected yet: its own queue holds them.
        case daemonNotConnected = "daemon_not_connected"
        /// Only the terminal's live view can take them.
        case liveView = "live_view"
    }

    /// The keys that waited for one reason in the picture phase, and how long they waited in all.
    public nonisolated struct WaitTotal: Sendable, Equatable {
        public let reason: WaitReason
        public let keys: Int
        public let waited: Duration

        public init(reason: WaitReason, keys: Int, waited: Duration) {
            (self.reason, self.keys, self.waited) = (reason, keys, waited)
        }
    }

    /// Gives `events` to `target`'s live terminal view, in order; false while it has none.
    public typealias Deliver = @MainActor (_ target: Target, _ events: [NSEvent]) -> Bool
    /// The answer to one ``Forward``.
    public typealias Answered = @MainActor @Sendable (_ outcome: SendOutcome) -> Void
    /// Sends `events` to `target`'s terminal input by its id, in order, and calls `answered` once.
    public typealias Forward = @MainActor (_ target: Target, _ events: [NSEvent], _ answered: @escaping Answered) -> Void
    /// Sends `events`, typed in `window` before it could decide them, through the key router again, in order; false
    /// while the window still cannot decide them (they stay held, ahead of any later key).
    public typealias Replay = @MainActor (_ window: String, _ events: [NSEvent]) -> Bool
    /// Tells the person why keys typed in `window` reached nothing and keeps their text: `text` is what every refused
    /// key of `window` typed since the person was last done with it, in typing order; `reason` the daemon's answer
    /// (nil: nothing could take them).
    public typealias Refuse = @MainActor (_ window: String, _ text: String, _ reason: String?) -> Void

    /// A terminal's keys that are not in its view yet.
    private struct Waiting {
        /// The send on its way to the daemon.
        var inFlight: [NSEvent]?
        /// The keys typed behind it, in order.
        var queue: [NSEvent] = []
        /// When the queue's keys began waiting for the live view (nil: they go by id).
        var forViewSince: ContinuousClock.Instant?
    }

    private struct Undecided {
        var events: [NSEvent]
        let since: ContinuousClock.Instant
    }

    private struct Picture {
        weak var shell: NSWindow?
        let raise: @MainActor (_ pane: String?) -> Void
    }

    /// The windows showing their picture, with the call that raises a pane's build slice to the next frame.
    private var pictures: [String: Picture] = [:] { didSet { noteActivity() } }
    /// Each terminal whose keys are not in its view yet.
    private var waiting: [Target: Waiting] = [:] { didSet { noteActivity() } }
    /// Each window's keys it could not decide yet, in the order typed; windows in the order their first key came.
    private var undecided: [String: Undecided] = [:] { didSet { noteActivity() } }
    private var undecidedOrder: [String] = []
    private var raised: Set<Target> = []
    private var raisedWindows: Set<String> = []
    /// Each window's refused text the person is not done with, in typing order.
    private var keptText: [String: String] = [:]
    /// Every wait so far, per reason: keys and time.
    private var waits: [WaitReason: (keys: Int, waited: Duration)] = [:]
    /// The totals went out (once: each launch value is sent once).
    private var sentTotals = false
    private var wasActive = false
    private let deliver: Deliver
    private let now: @MainActor () -> ContinuousClock.Instant

    /// Runs with the new value whenever ``isActive`` changes (the key router's mode).
    public var onActiveChange: (@MainActor (Bool) -> Void)?
    /// Sends a terminal's keys by its id (the key router: the daemon's input); nil has no way by id, so keys wait
    /// for the live view.
    public var forward: Forward?
    /// Decides a window's undecided keys again (the key router); nil keeps them until the picture leaves.
    public var replay: Replay?
    /// Shows the person keys that reached nothing and keeps their text (the key router: the refusal notice).
    public var refuse: Refuse?
    /// Gets the waits' totals, one per reason (zeros too), once: when the picture phase first ends with no key
    /// waiting (the key router: launch values and their signposts).
    public var onWaitTotals: (@MainActor ([WaitTotal]) -> Void)?
    /// `macos-option-as-alt` now (nil: not known, so Option keys wait for the live view). The key router reads
    /// Ghostty's config; tests pass their own.
    public var optionAsAlt: @MainActor () -> TypedTerminalInput.OptionAsAlt? = { nil }
    /// Whether an input method is the selected input source now (its keys wait for the live view). The key router
    /// reads the terminals' input sources; tests pass their own.
    public var selectsInputMethod: @MainActor () -> Bool = { false }
    /// Keys refused so far (each reached ``refuse``).
    public private(set) var refused = 0

    /// - Parameter now: the clock's reading (tests pass their own).
    public init(now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }, deliver: @escaping Deliver) {
        self.now = now
        self.deliver = deliver
    }

    /// The buffer's clock now: a wait the key router measures (``noteWait(_:keys:since:)``) starts here.
    public var clock: ContinuousClock.Instant { now() }

    /// Some window shows its picture or some key waits: the key router asks ``holds(window:)`` per key.
    public var isActive: Bool { !pictures.isEmpty || !waiting.isEmpty || !undecided.isEmpty }

    /// Whether keys typed in `window` may go through here: it shows its picture, or earlier keys of it still wait.
    public func holds(window: String) -> Bool {
        pictures[window] != nil || undecided[window] != nil || waiting.keys.contains { $0.window == window }
    }

    /// Whether `window` shows its picture (between ``begin(window:shell:raise:)`` and ``end(window:)``).
    public func showsPicture(window: String) -> Bool { pictures[window] != nil }

    /// The window showing its picture in `shell`, for a key typed there before the window has a controller.
    public func window(showing shell: NSWindow) -> String? {
        pictures.first { $0.value.shell === shell }?.key
    }

    /// Whether keys typed for `target` are not in its view yet: a later key goes behind them.
    public func isHolding(_ target: Target) -> Bool { waiting[target] != nil }

    /// Whether keys typed in `window` wait to be decided: a later key of it waits behind them.
    public func isHoldingUndecided(window: String) -> Bool { undecided[window] != nil }

    /// The refused text of `window` the person is not done with (nil: none).
    public func kept(window: String) -> String? { keptText[window] }

    /// The person is done with `window`'s refused text (closed its notice, or copied it): the next refusal starts over.
    public func forgetKept(window: String) { keptText[window] = nil }

    /// Records keys that waited from `since` for `reason` (also the key router's own waits: the daemon's first
    /// connection); the totals go out once the picture phase ends (``onWaitTotals``).
    public func noteWait(_ reason: WaitReason, keys: Int, since: ContinuousClock.Instant) {
        let total = waits[reason] ?? (keys: 0, waited: .zero)
        waits[reason] = (keys: total.keys + keys, waited: total.waited + since.duration(to: now()))
    }

    /// `window` shows its picture in `shell` from now on; `raise` builds a pane's slice in the next frame (nil: the
    /// focused pane, which the window does not know yet).
    public func begin(window: String, shell: NSWindow?, raise: @escaping @MainActor (_ pane: String?) -> Void) {
        pictures[window] = Picture(shell: shell, raise: raise)
    }

    /// `window`'s picture left (every region live, its bound, a resize, its window closed): its keys go on now, and
    /// the ones that still cannot (no live view, no window to decide them) are refused, their text kept.
    public func end(window: String) {
        pictures[window] = nil
        raisedWindows.remove(window)
        raised = raised.filter { $0.window != window }
        retry()
    }

    /// Sends `event`, typed for `target`'s terminal, on at once (its live view, else by its id), behind the keys of
    /// it not in the view yet. Raises that pane's slice to the next frame (once per target while the picture shows).
    public func hold(_ event: NSEvent, for target: Target) {
        if pictures[target.window] != nil, raised.insert(target).inserted { pictures[target.window]?.raise(target.pane) }
        waiting[target, default: Waiting()].queue.append(event)
        pump(target)
    }

    /// Holds `event`, typed in `window` before the window could decide it and with no terminal to send it to, until
    /// ``replay`` can, and raises the window's focused-pane slice to the next frame (once per window).
    public func holdUndecided(_ event: NSEvent, window: String) {
        if raisedWindows.insert(window).inserted { pictures[window]?.raise(nil) }
        if undecided[window] == nil {
            undecidedOrder.append(window)
            // A wait with a reason: no destination exists until the window decides focus. Its bound is the picture's
            // (``end(window:)``), where keys it still cannot decide are refused, their text kept; never dropped.
            undecided[window] = Undecided(events: [event], since: now())
        } else {
            undecided[window]?.events.append(event)
        }
    }

    /// Sends every window's undecided keys through the router when it can decide them, and gives every terminal its
    /// keys that wait for its view when it is live; refuses those of a window whose picture left.
    public func retry() {
        for window in undecidedOrder { replayUndecided(window) }
        for target in Array(waiting.keys) { pump(target) }
    }

    private func replayUndecided(_ window: String) {
        guard let held = undecided[window] else { return }
        // The picture left: this wait ends here either way. Noted before the queue empties, which can end the phase
        // (and send the totals).
        let atBound = pictures[window] == nil
        if atBound { noteWait(.undecided, keys: held.events.count, since: held.since) }
        // Out of the queue first: the router decides them as new keys, and a key for a terminal goes on to it.
        undecided[window] = nil
        undecidedOrder.removeAll { $0 == window }
        if replay?(window, held.events) == true {
            if !atBound { noteWait(.undecided, keys: held.events.count, since: held.since) }
            return
        }
        // The picture left and the window still cannot decide them: nothing will (it closed before it was built).
        guard !atBound else { return refuseKeys(held.events, window: window, reason: nil) }
        undecided[window] = held
        undecidedOrder.insert(window, at: 0)
    }

    /// Moves `target`'s queue on when no send of it is on its way: into its live view, else by its id, else (only the
    /// view can take them) it waits for the view until the picture leaves, then is refused.
    private func pump(_ target: Target) {
        guard var state = waiting[target], state.inFlight == nil else { return }
        guard !state.queue.isEmpty else {
            waiting[target] = nil
            return
        }
        if deliver(target, state.queue) {
            if let since = state.forViewSince { noteWait(.liveView, keys: state.queue.count, since: since) }
            waiting[target] = nil
            return
        }
        guard state.forViewSince == nil, let forward else {
            let since = state.forViewSince ?? now()
            guard pictures[target.window] != nil else {
                // Noted before the queue empties, which can end the phase (and send the totals).
                noteWait(.liveView, keys: state.queue.count, since: since)
                waiting[target] = nil
                return refuseKeys(state.queue, window: target.window, reason: nil)
            }
            state.forViewSince = since
            waiting[target] = state
            return
        }
        let sending = state.queue
        state.inFlight = sending
        state.queue = []
        waiting[target] = state
        forward(target, sending) { [weak self] outcome in self?.answered(target, outcome) }
    }

    /// The daemon answered `target`'s send.
    private func answered(_ target: Target, _ outcome: SendOutcome) {
        guard var state = waiting[target], let sent = state.inFlight else { return }
        state.inFlight = nil
        switch outcome {
        case .taken:
            break
        case .keptForView(let taken):
            state.queue = Array(sent.dropFirst(taken)) + state.queue
            state.forViewSince = now()
        case .refused(let taken, let reason), .mayNotHaveArrived(let taken, let reason):
            waiting[target] = nil
            return refuseKeys(Array(sent.dropFirst(taken)) + state.queue, window: target.window, reason: reason)
        }
        waiting[target] = state
        pump(target)
    }

    private func refuseKeys(_ events: [NSEvent], window: String, reason: String?) {
        guard !events.isEmpty else { return }
        refused += events.count
        // Text only: a key sent by name (Return, an arrow, a chord) has no text to paste again. Option reads as the
        // send reads it; not known, it composed text (a key that never went by id keeps what it typed).
        let optionAsAlt = optionAsAlt() ?? .off
        let typed = events.compactMap { TypedTerminalInput($0, optionAsAlt: optionAsAlt)?.text }.joined()
        let text = (keptText[window] ?? "") + typed
        keptText[window] = text
        refuse?(window, text, reason)
    }

    private func noteActivity() {
        guard isActive != wasActive else { return }
        wasActive = isActive
        onActiveChange?(wasActive)
        if !wasActive { sendTotals() }
    }

    /// The waits' totals, once, when the picture phase first ends with no key waiting.
    private func sendTotals() {
        guard !sentTotals, let onWaitTotals else { return }
        sentTotals = true
        onWaitTotals(WaitReason.allCases.map { reason in
            WaitTotal(reason: reason, keys: waits[reason]?.keys ?? 0, waited: waits[reason]?.waited ?? .zero)
        })
    }
}
