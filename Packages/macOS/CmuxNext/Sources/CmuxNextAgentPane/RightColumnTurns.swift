public import CmuxNextWakeups

/// Opens on the right of a source pane, one at a time per source (``RightColumnPlacement``): each open
/// decides its place from the column as it is when its turn comes, after the open before it has landed.
/// Two opens never read the same column, so neither splits where the other already did (reviews of
/// #28044 at c15e0d89 and e954bd85).
///
/// The app owns one instance (its `LinkOpener`), and every open on the right goes through it: links,
/// files, folders and browser tabs, and subagents, side chats, Session Info sessions and transcript
/// session cards.
@MainActor
public final class RightColumnTurns {
    /// The pane an open is beside (the caller's pane identity).
    public typealias Source = AnyHashable
    /// An open's turn: it gets `done`, which it calls once its open has landed or failed.
    public typealias Turn = @MainActor (_ done: @escaping @MainActor () -> Void) -> Void

    /// How long a turn holds its source when its open never reports back.
    public let turnLimit: Duration
    /// The sources with an open under way.
    private var running: Set<Source> = []
    /// The opens waiting for their source, oldest first.
    private var waiting: [Source: [Turn]] = [:]

    public init(turnLimit: Duration = .seconds(30)) {
        self.turnLimit = turnLimit
    }

    /// Runs `turn` now, or once every open already under way beside `source` has landed or failed.
    /// Returns whether it ran now (false: it waits its turn).
    @discardableResult
    public func serially(beside source: Source, _ turn: @escaping Turn) -> Bool {
        guard !running.contains(source) else {
            waiting[source, default: []].append(turn)
            return false
        }
        run(turn, beside: source)
        return true
    }

    /// Whether an open beside `source` is under way.
    public func isBusy(beside source: Source) -> Bool { running.contains(source) }

    private func run(_ turn: Turn, beside source: Source) {
        running.insert(source)
        let hold = Hold { [weak self] in self?.next(after: source) }
        hold.backstop.schedule(after: turnLimit) { @MainActor [hold] in hold.end() }
        turn { hold.end() }
    }

    /// Ends `source`'s turn and starts the next waiting one, if any.
    private func next(after source: Source) {
        running.remove(source)
        guard var queue = waiting[source], !queue.isEmpty else { waiting[source] = nil; return }
        let turn = queue.removeFirst()
        waiting[source] = queue.isEmpty ? nil : queue
        run(turn, beside: source)
    }

    /// One turn's hold on its source: it ends once, whichever comes first, its open's `done` or the backstop.
    @MainActor private final class Hold {
        let backstop = DemandTimer(owner: "RightColumnTurns.turn")
        private let ended: @MainActor () -> Void
        private var isOver = false

        init(_ ended: @escaping @MainActor () -> Void) { self.ended = ended }

        func end() {
            guard !isOver else { return }
            isOver = true
            backstop.cancel()
            ended()
        }
    }
}
