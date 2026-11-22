public import CmuxNextDaemon
import CmuxNextWakeups
public import Observation

/// One personal group's cleanup after a close that may empty it (cx-rcby),
/// shared with that close's Undo: it deletes the group once the close
/// lands and the group is still an unpinned group with no live member;
/// Undo either stops it before the delete goes, or waits for the delete in
/// flight and then reopens exactly the record that delete made. The rule
/// between the two (`step`, `record`) reads no app state.
@MainActor @Observable
public final class GroupCloseCleanup {
    /// Where the cleanup is.
    public enum State: Equatable, Sendable {
        /// The delete is not sent yet (its close may still be landing).
        case waiting
        /// Undo came first: no delete is sent, and the group stays.
        case cancelled
        /// The delete is in flight; `before` is the closed history just before it was sent.
        case deleting(before: Set<String>)
        /// The group stayed: pinned, a refused close, a member placed meanwhile, or a failed delete.
        case kept
        /// This close's delete landed; `before` is the closed history just before it was sent.
        case deleted(before: Set<String>)
    }

    /// What Undo does about the group.
    public enum Step: Equatable, Sendable {
        /// Stop the cleanup before it sends its delete: the group stays and the workspaces reopen into it.
        case cancel
        /// Wait for the delete in flight to finish, then ask again.
        case wait
        /// The close deleted nothing: Undo has no group record to reopen.
        case nothing
        /// Reopen the record this close's delete made (the first one for the group after `after`).
        case reopenRecord(after: Set<String>)
    }

    public nonisolated static func step(_ state: State) -> Step {
        switch state {
        case .waiting: .cancel
        case .deleting: .wait
        case .cancelled, .kept: .nothing
        case .deleted(let before): .reopenRecord(after: before)
        }
    }

    /// The record the delete of `group` made: the oldest record for it that
    /// was not in the history (`before`) when the delete was sent. A later,
    /// unrelated delete of the same group makes a newer record, never this one.
    public nonisolated static func record(of group: String, after before: Set<String>,
                                          newestFirst history: [(id: String, group: String?)]) -> String? {
        history.last { $0.group == group && !before.contains($0.id) }?.id
    }

    /// How long a run waits for its close to reach the home store. A close
    /// the daemon refuses leaves its members live, so without a limit the
    /// wait would never end; a close that lands is seen well within it.
    public nonisolated static let settleLimit: Duration = .seconds(5)

    /// The store reads and the delete, injected so a test drives them.
    public struct Home: Sendable {
        /// Whether the group still exists.
        public var exists: @MainActor @Sendable () -> Bool
        /// Whether it is an unpinned group with no live member.
        public var isEmptyUnpinned: @MainActor @Sendable () -> Bool
        /// Sends the delete; true when it went to the group and landed.
        public var delete: @MainActor @Sendable () async -> Bool
        /// The closed history, newest first.
        public var history: @MainActor @Sendable () -> [(id: String, group: String?)]

        public init(exists: @escaping @MainActor @Sendable () -> Bool, isEmptyUnpinned: @escaping @MainActor @Sendable () -> Bool,
                    delete: @escaping @MainActor @Sendable () async -> Bool,
                    history: @escaping @MainActor @Sendable () -> [(id: String, group: String?)]) {
            self.exists = exists
            self.isEmptyUnpinned = isEmptyUnpinned
            self.delete = delete
            self.history = history
        }
    }

    public let group: WorkspaceGroupID
    public private(set) var state: State = .waiting
    @ObservationIgnored private let home: Home
    @ObservationIgnored private var running = false
    @ObservationIgnored private var finished: [CheckedContinuation<Void, Never>] = []

    public init(_ group: WorkspaceGroupID, home: Home) {
        self.group = group
        self.home = home
    }

    /// Deletes the group once the close lands: waits (at most `limit`) until
    /// it is gone or empty or Undo stopped it, then deletes it if it still is
    /// an unpinned group with no live member. A run that kept the group may
    /// run again (a later close of the same batch may empty it).
    public func run(limit: Duration = GroupCloseCleanup.settleLimit) async {
        guard !running, state == .waiting || state == .kept else { return }
        running = true
        defer { running = false }
        state = .waiting
        let home = home
        let settled: @MainActor @Sendable () -> Bool = { [weak self] in
            self?.state != .waiting || !home.exists() || home.isEmptyUnpinned()
        }
        if !settled() { await ObservationDeadline(owner: "group-close-cleanup").until(settled, limit: limit) }
        // Undo stopped it, or the group is no longer this close's to delete.
        guard state == .waiting else { return }
        guard home.isEmptyUnpinned() else { return finish(.kept) }
        let before = Set(home.history().map(\.id))
        state = .deleting(before: before)
        finish(await home.delete() ? .deleted(before: before) : .kept)
    }

    /// For Undo: stops the cleanup if it has not sent its delete, or waits
    /// for the delete in flight; then the id of the closed record this
    /// close's delete made, once it is in the history (at most `limit`), or
    /// nil when the close deleted nothing.
    public func undo(limit: Duration) async -> String? {
        if Self.step(state) == .wait { await withCheckedContinuation { finished.append($0) } }
        switch Self.step(state) {
        case .cancel, .wait:
            // Not sent (a kept cleanup that a later settle started again counts too): it never will be.
            state = .cancelled
            return nil
        case .nothing:
            // A kept group never goes after Undo, even when a later settle of the batch would run it again.
            if state == .kept { state = .cancelled }
            return nil
        case .reopenRecord(let before):
            let home = home, group = group.rawValue
            let found: @MainActor @Sendable () -> String? = { Self.record(of: group, after: before, newestFirst: home.history()) }
            if found() == nil { await ObservationDeadline(owner: "group-close-cleanup-undo").until({ found() != nil }, limit: limit) }
            return found()
        }
    }

    private func finish(_ outcome: State) {
        state = outcome
        let waiting = finished
        finished = []
        for continuation in waiting { continuation.resume() }
    }
}
