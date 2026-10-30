public import AppKit
public import CmuxNextActions
public import CmuxNextDaemon
public import CmuxNextDaemonService
import CmuxNextSidebar

/// A person's close of several selected sidebar rows (Cmd-W, the row menu's Close or the
/// sidebar's Delete on a selection, #23110) as one batch. Leo 2026-10-21: "it's really slow and
/// it's missing a LOT... and it's also 2 lines tall". Each row used to run its own Close
/// Workspace: its own question, titled with its name (a long name wraps to two lines), queued
/// behind the others and not confirmed by Return, then its own turn in the window's lane, which
/// waited for the daemon and the store before the next row's close started. Now one question covers
/// them all (`question`: "Close N workspaces?"), asked while the rows stay in place when it likely
/// shows (`mayAsk`); once it is answered Close every row leaves in one sidebar pass (`hide`). Otherwise
/// the rows leave at the press and the terminals are still asked behind them (Cancel: `restore`).
/// Every close goes out at once in one lane turn, and "Closed N workspaces" with
/// Undo brings them all back (`offerUndo`), as the other bulk closes do. The App wires it
/// (`WorkspaceSelectionClose`); the flow lives here so CmuxNextApp does not grow (SW14).
@MainActor
public struct WorkspaceSelectionCloseFlow {
    public typealias Member = (WorkspaceModel, DaemonService)

    /// Rows whose batch close has started and not settled (each leaves as its own close settles): a second
    /// press (this batch, or Close Workspace on the row the window keeps) sends nothing for them. The app
    /// has one (`AppServices.selectionCloses`), passed to every batch close and to Close Workspace.
    @MainActor public final class Running {
        public private(set) var ids: Set<String> = []

        public init() {}

        /// Whether workspace `id` may join a batch: no close of it has started.
        public func canStart(_ id: String) -> Bool {
            !ids.contains(id) && !ClosingWorkspaces.shared.ids.contains(id) && !WorkspaceCloseFlow.running.contains(id)
        }

        func formUnion(_ closing: [String]) { ids.formUnion(closing) }
        func subtract(_ settled: [String]) { ids.subtract(settled) }
        func remove(_ id: String) { ids.remove(id) }
    }

    /// The app's batch closes under way.
    public let running: Running

    /// Every row leaves and the selection moves, in one sidebar pass (InstantClose): the ids that left.
    public var hide: @MainActor ([String]) -> [String]
    /// Whether the batch will likely ask, read in the press's turn from the store. True: the rows stay
    /// until the answer; false: they leave at once.
    public var mayAsk: @MainActor () -> Bool
    /// Asks the terminals for a running program: nil to close without asking, else the one question
    /// for the whole selection (true: Close), asked while the rows stay (as WorkspaceCloseFlow does).
    public var question: @MainActor () async -> (@MainActor () async -> Bool)?
    /// The person cancelled rows that left at the press: the window shows its workspace again unless
    /// the person moved on meanwhile.
    public var restore: @MainActor () -> Void
    /// Whether a workspace is still listed (it may close another way while the question is up).
    public var listed: @MainActor (String) -> Bool
    /// The app's machines: a close waiting for its machine ends when the machine leaves the app.
    public var machines: @MainActor @Sendable () -> [DaemonService]
    /// The one "Closed N workspaces" toast with Undo for `names` (none for fewer than two, or with no
    /// window left open); `undone` runs when its Undo does.
    public var offerUndo: @MainActor (_ names: [String], _ undone: @escaping @MainActor () -> Void) -> Void
    /// The window whose lane the closes take, and the window a refusal toast shows in.
    public var window: String
    public var toastWindow: NSWindow?

    public init(hide: @escaping @MainActor ([String]) -> [String], mayAsk: @escaping @MainActor () -> Bool,
                question: @escaping @MainActor () async -> (@MainActor () async -> Bool)?,
                restore: @escaping @MainActor () -> Void, listed: @escaping @MainActor (String) -> Bool,
                machines: @escaping @MainActor @Sendable () -> [DaemonService],
                offerUndo: @escaping @MainActor (_ names: [String], _ undone: @escaping @MainActor () -> Void) -> Void,
                window: String, toastWindow: NSWindow?, running: Running) {
        self.running = running
        self.hide = hide
        self.mayAsk = mayAsk
        self.question = question
        self.restore = restore
        self.listed = listed
        self.machines = machines
        self.offerUndo = offerUndo
        self.window = window
        self.toastWindow = toastWindow
    }

    /// Starts the close of `members` (each `canStart`); nil when there is none.
    public func start(_ members: [Member]) -> ActionWork? {
        guard !members.isEmpty else { return nil }
        let closing = members.map(\.0.id)
        running.formUnion(closing)
        // Every close path tells `willClose` before it closes (WorkspaceClose); in press order. A question
        // that likely shows keeps the rows (and tells nobody) until it is answered.
        let early = mayAsk() ? nil : (terminals: members.map { WorkspaceClose.closing($0.0, on: $0.1) }, hidden: hide(closing))
        return Task { @MainActor in
            if let ask = await question(), !(await ask()) {
                running.subtract(closing)
                // Rows that never moved: nothing to bring back.
                if let early {
                    for id in early.hidden { ClosingWorkspaces.shared.end(id, refused: false, in: nil) }
                    restore()
                }
                return nil
            }
            let terminals = early?.terminals ?? members.map { WorkspaceClose.closing($0.0, on: $0.1) }
            let hidden = early?.hidden ?? hide(closing)
            // Closed another way while the question was up (the CLI, another window): nothing to send, and
            // its row is no longer closing.
            let batch = zip(members, terminals).filter { listed($0.0.0.id) }
            let sent = Set(batch.map { $0.0.0.id })
            running.subtract(closing.filter { !sent.contains($0) })
            for id in hidden where !sent.contains(id) { ClosingWorkspaces.shared.end(id, refused: false, in: nil) }
            let live = batch.filter { $0.0.1.isLive }, offline = batch.filter { !$0.0.1.isLive }
            // Every row of the batch that closed, the offline ones too, under one toast and one Undo: shown once
            // the live rows settled, and shown again in place (same id) as each offline row closes later.
            let outcome = Outcome(offer: offerUndo)
            // A machine that is not connected (a paused Cloud VM): its closes wait for it outside the
            // window's lane, so later creates and closes never wait for it (WorkspaceCloseFlow).
            for pair in offline {
                // task-owner: one close that waits for its machine (until it connects or leaves the app)
                Task { @MainActor in outcome.add(await settle([(pair.0, await send(pair.0, terminals: pair.1, waits: true))])) }
            }
            return await WorkspaceLanes.shared.run(in: window) {
                // task-owner: one close request each, all sent now; awaited right below.
                let started = live.map { pair in Task { @MainActor in (pair.0, await send(pair.0, terminals: pair.1, waits: false)) } }
                var results: [(Member, ActionWorkFailure?)] = []
                for task in started { results.append(await task.value) }
                outcome.liveSettled(await settle(results))
                return results.first { $0.1 != nil }?.1
            }.value
        }
    }

    /// The names a batch closed, from inside the window's lane and from the offline closes after it.
    @MainActor private final class Outcome {
        private var closed: [String] = []
        private var shown = false
        /// The toast's Undo ran: it reopened what had closed then, so a later offline close
        /// no longer joins it (Reopen Closed Workspace and History still have that one).
        private var undone = false
        private let offer: @MainActor ([String], @escaping @MainActor () -> Void) -> Void

        init(offer: @escaping @MainActor ([String], @escaping @MainActor () -> Void) -> Void) { self.offer = offer }

        /// The live rows settled: the toast shows for everything closed so far.
        func liveSettled(_ names: [String]) {
            closed += names
            shown = true
            offer(closed) { [weak self] in self?.undone = true }
        }

        /// An offline row settled; once the toast has shown, and until its Undo ran, it shows again with it.
        func add(_ names: [String]) {
            guard !names.isEmpty, !undone else { return }
            closed += names
            if shown { offer(closed) { [weak self] in self?.undone = true } }
        }
    }

    /// Ends the closes of `results`: one that went through stays hidden until its store has applied its
    /// events (the row is gone there); a refusal lists its row again, with one toast in `toastWindow` for all
    /// of them. Returns the names that closed.
    private func settle(_ results: [(Member, ActionWorkFailure?)]) async -> [String] {
        var daemons: [ObjectIdentifier: DaemonService] = [:]
        for (member, failure) in results where failure == nil { daemons[ObjectIdentifier(member.1)] = member.1 }
        for daemon in daemons.values {
            if let connection = daemon.connection { await daemon.store.applied(through: await connection.eventSequence()) }
        }
        let firstRefused = results.first { $0.1 != nil }?.0.0.id
        for (member, failure) in results {
            // Settled: a refused row can be closed again at once.
            running.remove(member.0.id)
            ClosingWorkspaces.shared.end(member.0.id, refused: failure != nil, in: member.0.id == firstRefused ? toastWindow : nil)
        }
        return results.filter { $0.1 == nil }.map { $0.0.0.name }
    }

    /// One workspace's close on its own machine (`waits`: until that machine connects).
    private func send(_ member: Member, terminals: [WorkspaceClose.Terminal], waits: Bool) async -> ActionWorkFailure? {
        let (workspace, daemon) = member, machines = machines
        guard let key = workspace.key else { return nil }
        return await daemon.failureOnceConnected("close-workspace", waits: waits, while: { machines().contains { $0 === daemon } }) { connection in
            try await ClosingWorkspaces.shared.refusal()
            try await WorkspaceClose.close(key, terminals: terminals, on: connection)
        }
    }
}
