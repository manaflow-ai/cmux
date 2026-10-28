public import AppKit

/// Keys typed while a window shows its launch picture (p08-startup-061). A key changes only this buffer in its turn
/// and asks the window to build its focused pane's slice in the next frame (``begin(window:shell:raise:)``); it never
/// builds the window, and no key waits for the window or its terminal view to be built:
///
/// - A key for a terminal whose live view is not built (``hold(_:for:)``) goes at once to that terminal's input by its
///   id (``forward``): the daemon takes input for a terminal before any view of it is live. One send per terminal is
///   on its way at a time, and keys typed meanwhile go behind it, so none overtakes another: when the daemon took
///   it, the keys behind it go to the live view if it is live by then (``init(deliver:)``), else by id again. A
///   terminal whose view is live and has nothing on its way takes its keys on the usual path.
/// - Keys typed before the window can decide them (it has no controller yet, or its focus has not resolved) go to
///   the terminal its saved session restores focus to, by id (the key router names it). Only when no such terminal
///   can be named, or for a chord (it may be one of the window's shortcuts), they wait whole
///   (``holdUndecided(_:window:)``) and go through the key router again, in order, once ``replay`` can decide them;
///   a later key of the window queues behind them.
///
/// No key is dropped silently. A key the daemon refuses, with every key behind it, and keys the window can never
/// decide (its picture left with no window behind it) are refused through ``refuse`` with the text they carry, so
/// the person sees why and keeps it.
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
/// keys.end(window: "w1")                                                   // the picture left
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

    /// Gives `events` to `target`'s live terminal view, in order; false while it has none.
    public typealias Deliver = @MainActor (_ target: Target, _ events: [NSEvent]) -> Bool
    /// The daemon's answer to one ``Forward``: nil once it took the keys (or may have: they are never sent twice),
    /// else why not.
    public typealias Answered = @MainActor @Sendable (_ refusal: String?) -> Void
    /// Sends `events` to `target`'s terminal input by its id, in order, and calls `answered` once.
    public typealias Forward = @MainActor (_ target: Target, _ events: [NSEvent], _ answered: @escaping Answered) -> Void
    /// Sends `events`, typed in `window` before it could decide them, through the key router again, in order; false
    /// while the window still cannot decide them (they stay held, ahead of any later key).
    public typealias Replay = @MainActor (_ window: String, _ events: [NSEvent]) -> Bool
    /// Tells the person why keys typed in `window` reached nothing and keeps their text: `text` is everything of
    /// `window` refused so far, in typing order; `reason` the daemon's answer (nil: nothing could take them).
    public typealias Refuse = @MainActor (_ window: String, _ text: String, _ reason: String?) -> Void

    /// A terminal's keys: the send on its way to the daemon, and the keys typed behind it.
    private struct Waiting {
        let sent: [NSEvent]
        var behind: [NSEvent] = []
    }

    private struct Picture {
        weak var shell: NSWindow?
        let raise: @MainActor (_ pane: String?) -> Void
    }

    /// The windows showing their picture, with the call that raises a pane's build slice to the next frame.
    private var pictures: [String: Picture] = [:] { didSet { noteActivity() } }
    /// Each terminal with a send on its way.
    private var waiting: [Target: Waiting] = [:] { didSet { noteActivity() } }
    /// Each window's keys it could not decide yet, in the order typed; windows in the order their first key came.
    private var undecided: [String: [NSEvent]] = [:] { didSet { noteActivity() } }
    private var undecidedOrder: [String] = []
    private var raised: Set<Target> = []
    private var raisedWindows: Set<String> = []
    /// Each window's refused text so far, in typing order.
    private var kept: [String: String] = [:]
    private var wasActive = false
    private let deliver: Deliver

    /// Runs with the new value whenever ``isActive`` changes (the key router's mode).
    public var onActiveChange: (@MainActor (Bool) -> Void)?
    /// Sends a terminal's keys by its id (the key router: the daemon's input); nil has no way to a terminal that
    /// is still a picture, so its keys are refused at once.
    public var forward: Forward?
    /// Decides a window's undecided keys again (the key router); nil keeps them until the picture leaves.
    public var replay: Replay?
    /// Shows the person keys that reached nothing and keeps their text (the key router: the refusal notice).
    public var refuse: Refuse?
    /// Keys refused so far (each reached ``refuse``).
    public private(set) var refused = 0

    public init(deliver: @escaping Deliver) {
        self.deliver = deliver
    }

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

    /// Whether keys typed for `target` are on their way to it: a later key goes behind them.
    public func isHolding(_ target: Target) -> Bool { waiting[target] != nil }

    /// Whether keys typed in `window` wait to be decided: a later key of it waits behind them.
    public func isHoldingUndecided(window: String) -> Bool { undecided[window] != nil }

    /// `window` shows its picture in `shell` from now on; `raise` builds a pane's slice in the next frame (nil: the
    /// focused pane, which the window does not know yet).
    public func begin(window: String, shell: NSWindow?, raise: @escaping @MainActor (_ pane: String?) -> Void) {
        pictures[window] = Picture(shell: shell, raise: raise)
    }

    /// `window`'s picture left (every region live, its bound, a resize, its window closed): its undecided keys go on
    /// now, and the ones no window can decide any more are refused.
    public func end(window: String) {
        pictures[window] = nil
        raisedWindows.remove(window)
        raised = raised.filter { $0.window != window }
        retry()
    }

    /// Sends `event`, typed for `target`'s terminal, on at once: to its live view, else by its id; behind the keys
    /// on their way to it. Raises that pane's slice to the next frame (once per target while the picture shows).
    public func hold(_ event: NSEvent, for target: Target) {
        if pictures[target.window] != nil, raised.insert(target).inserted { pictures[target.window]?.raise(target.pane) }
        if waiting[target] != nil {
            waiting[target]?.behind.append(event)
            return
        }
        send([event], to: target)
    }

    /// Holds `event`, typed in `window` before the window could decide it and with no terminal to send it to, until
    /// ``replay`` can, and raises the window's focused-pane slice to the next frame (once per window).
    public func holdUndecided(_ event: NSEvent, window: String) {
        if raisedWindows.insert(window).inserted { pictures[window]?.raise(nil) }
        if undecided[window] == nil { undecidedOrder.append(window) }
        undecided[window, default: []].append(event)
    }

    /// Sends every window's undecided keys through the router when it can decide them; refuses the keys of a
    /// window whose picture left with no window behind it to decide them.
    public func retry() {
        for window in undecidedOrder { replayUndecided(window) }
    }

    private func replayUndecided(_ window: String) {
        guard let events = undecided[window] else { return }
        // Out of the queue first: the router decides them as new keys, and a key for a terminal goes on to it.
        undecided[window] = nil
        undecidedOrder.removeAll { $0 == window }
        if replay?(window, events) == true { return }
        // The picture left and the window still cannot decide them: nothing will (it closed before it was built).
        guard pictures[window] != nil else { return refuseKeys(events, window: window, reason: nil) }
        undecided[window] = events
        undecidedOrder.insert(window, at: 0)
    }

    /// `events` for `target`, with nothing on its way to it: to its live view, else by its id.
    private func send(_ events: [NSEvent], to target: Target) {
        if deliver(target, events) { return }
        guard let forward else { return refuseKeys(events, window: target.window, reason: nil) }
        waiting[target] = Waiting(sent: events)
        forward(target, events) { [weak self] refusal in self?.answered(target, refusal: refusal) }
    }

    /// The daemon answered `target`'s send: the keys behind it go on, or (refused) are refused with it.
    private func answered(_ target: Target, refusal: String?) {
        guard let done = waiting.removeValue(forKey: target) else { return }
        if let refusal { return refuseKeys(done.sent + done.behind, window: target.window, reason: refusal) }
        if !done.behind.isEmpty { send(done.behind, to: target) }
    }

    private func refuseKeys(_ events: [NSEvent], window: String, reason: String?) {
        refused += events.count
        let text = (kept[window] ?? "") + events.map { $0.characters ?? "" }.joined()
        kept[window] = text
        refuse?(window, text, reason)
    }

    private func noteActivity() {
        guard isActive != wasActive else { return }
        wasActive = isActive
        onActiveChange?(wasActive)
    }
}
