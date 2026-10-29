public import AppKit

/// The creations one window's held keys wait for (a split, a new terminal tab, a new workspace with its terminal): which
/// creation the person's newest intent asked for, under which focus generation, and the target its keys are stamped with
/// in the window's ``WindowInputQueue``. It holds no key and no timer: the keys wait in the queue, and the coordinator
/// releases or drops them from the current focus model (principled audit, lagFirstKey).
@MainActor
public final class CreationInputBuffer {
    /// A ticket names its buffer too: another window's buffer never takes it.
    public struct Ticket: Hashable, Sendable { fileprivate let id: Int; fileprivate let owner: ObjectIdentifier }

    /// One creation of this window.
    public struct Creation: Equatable, Sendable {
        /// The focus generation (the person's intent) it was asked under.
        public let generation: UInt64
        /// The target the keys typed for it are stamped with: its tab, or (no tab yet) a stand-in id that the coordinator
        /// moves to the tab its focus lands on (``WindowInputQueue/retarget(_:to:)``).
        public var target: WindowInputQueue.Target
        /// The tab of its new terminal's view when that view takes keys before the reply (cx-wb5.78).
        public var earlyTab: String?
        /// The tab it shows (a provisional pane, a stand-in), so a close of that tab drops its keys.
        public var tab: String?
        /// It makes a new workspace with its terminal: its keys wait until the window shows that workspace.
        public let newWorkspace: Bool
        /// Its reply came and it asked for its focus.
        public var landed = false
        /// The workspace a new-workspace creation made (its reply).
        public var workspace: String?

        /// Whether its target is a stand-in id (no tab known yet).
        public var awaitsTab: Bool { tab == nil }
    }

    private var creations: [Int: Creation] = [:]
    private var nextID = 0

    public init() {}

    /// No creation waits.
    public var isEmpty: Bool { creations.isEmpty }
    /// How many creations this buffer opened since it was made: a key run again that opened another changes it.
    public var openedCount: Int { nextID }
    /// The creations, oldest first.
    public var all: [(ticket: Ticket, creation: Creation)] {
        creations.keys.sorted().compactMap { id in creations[id].map { (Ticket(id: id, owner: ObjectIdentifier(self)), $0) } }
    }
    /// The newest creation: the keys typed now are its keys.
    public var newest: Creation? { creations.keys.max().flatMap { creations[$0] } }
    /// A creation still waits for its reply.
    public var hasPendingCreation: Bool { creations.values.contains { !$0.landed } }

    /// Opens a creation asked under `generation`. `earlyTab`: its new terminal's view takes keys before the reply.
    /// `tab`: the provisional tab it shows. `newWorkspace`: it makes a new workspace with its terminal.
    public func open(generation: UInt64, earlyTab: String? = nil, tab: String? = nil, newWorkspace: Bool = false) -> Ticket {
        nextID += 1
        let target = WindowInputQueue.Target(tab ?? (newWorkspace ? "creating-workspace:\(nextID)" : "creating:\(nextID)"))
        creations[nextID] = Creation(generation: generation, target: target, earlyTab: earlyTab, tab: tab, newWorkspace: newWorkspace)
        return Ticket(id: nextID, owner: ObjectIdentifier(self))
    }

    /// The creation behind `ticket`, while this buffer has it.
    public func creation(_ ticket: Ticket) -> Creation? {
        guard ticket.owner == ObjectIdentifier(self) else { return nil }
        return creations[ticket.id]
    }

    /// The reply of `ticket`'s creation came: `landed` (it asked for its focus, `workspace` the one it made) or not (it
    /// failed: it is removed and returned, so the coordinator drops its keys).
    @discardableResult
    public func resolve(_ ticket: Ticket, landed: Bool, workspace: String? = nil) -> Creation? {
        guard ticket.owner == ObjectIdentifier(self), var creation = creations[ticket.id] else { return nil }
        creation.earlyTab = nil
        guard landed, !creation.newWorkspace || workspace != nil else {
            creations[ticket.id] = nil
            return creation
        }
        creation.landed = true
        creation.workspace = workspace
        creations[ticket.id] = creation
        return creation
    }

    /// Removes the creations `matches` names and returns them, oldest first.
    @discardableResult
    public func remove(where matches: (Creation) -> Bool) -> [Creation] {
        let ids = creations.filter { matches($0.value) }.keys.sorted()
        return ids.compactMap { creations.removeValue(forKey: $0) }
    }

    /// The creations that show `tab`, removed (the person closed that tab before it took keys).
    public func cancel(tab: String) -> [Creation] { remove { $0.tab == tab && !$0.landed } }

    /// Whether a creation still waiting for its reply shows `tab`.
    public func isCreating(tab: String) -> Bool { creations.values.contains { $0.tab == tab && !$0.landed } }

    /// The early tab of the newest creation, when it still waits for its reply.
    public var newestEarlyTab: String? { newest.flatMap { $0.landed ? nil : $0.earlyTab } }

    /// Creation tab `key` is the daemon's tab `real` now (a Ctrl-` stand-in its daemon tab adopted). Returns the targets
    /// that changed, so the queue follows them.
    @discardableResult
    public func rekey(tab key: String, to real: String) -> [(WindowInputQueue.Target, WindowInputQueue.Target)] {
        var moved: [(WindowInputQueue.Target, WindowInputQueue.Target)] = []
        for (id, var creation) in creations {
            if creation.earlyTab == key { creation.earlyTab = real }
            if creation.tab == key { creation.tab = real }
            if creation.target.id == key {
                moved.append((creation.target, WindowInputQueue.Target(real)))
                creation.target = WindowInputQueue.Target(real)
            }
            creations[id] = creation
        }
        return moved
    }

    /// `ticket`'s creation's keys go to `target` from now on (its focus landed on that tab).
    public func setTarget(_ target: WindowInputQueue.Target, of ticket: Ticket) {
        guard ticket.owner == ObjectIdentifier(self), creations[ticket.id] != nil else { return }
        creations[ticket.id]?.target = target
        creations[ticket.id]?.tab = target.id
    }
}
