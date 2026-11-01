@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The forced-order red for #28425: a classic import's slot moves go to the sidebar document
/// (`sidebar.apply`), and on a loaded runner their replies trail the run. Here every document change
/// and adopt is held before it reaches the daemon, with no clock: a held one goes on only once someone
/// waits for the document to settle (`SidebarDocStore.settled()`), which is what the import's group
/// write and the check's read must do. A read that does not wait finds the moves still held.
@MainActor @Suite(.serialized, .ownsSidebarDocStore, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ClassicUpgradeHeldDocumentTests {
    /// Holds each change and adopt before it is sent, until ``release()``; one sent while someone waits
    /// in `settled()` (`waiting`) goes on at once.
    @MainActor final class HeldRemote: SidebarDocRemote {
        private let inner: any SidebarDocRemote
        private var held: [CheckedContinuation<Void, Never>] = []
        /// Whether someone waits for the document to settle now.
        var waiting: @MainActor () -> Bool = { false }
        /// Changes and adopts that were held at some point.
        private(set) var everHeld = 0
        /// Changes and adopts held now.
        var holding: Int { held.count }

        init(_ inner: any SidebarDocRemote) {
            self.inner = inner
        }

        var isAvailable: Bool { inner.isAvailable }
        func get() async throws -> Data { try await inner.get() }
        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply {
            await gate()
            return try await inner.move(items, to: target, key: key)
        }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply {
            await gate()
            return try await inner.pin(items, key: key)
        }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply {
            await gate()
            return try await inner.unpin(items, key: key)
        }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply {
            await gate()
            return try await inner.adopt(refs, key: key)
        }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply {
            await gate()
            return try await inner.apply(ops: ops, key: key)
        }

        /// Sends every held change on, in the order they came.
        func release() {
            let ready = held
            held = []
            for change in ready { change.resume() }
        }

        private func gate() async {
            guard !waiting() else { return }
            everHeld += 1
            await withCheckedContinuation { held.append($0) }
        }
    }

    @Test func theTreeIsReadOnlyOnceHeldDocumentMovesLand() async throws {
        let profile = ClassicUpgradeProfile.small
        let mac = try ClassicUpgradeSimulator.Mac()
        try mac.save(profile)
        let before = try mac.classicDigest()
        var made: HeldRemote?
        let sim = try ClassicUpgradeSimulator(mac: mac, documentRemote: { inner in
            let held = HeldRemote(inner)
            made = held
            return held
        })
        let remote = try #require(made, "the simulation did not make its sidebar document")
        let document = try #require(SidebarDocStore.current)
        // Someone waits for the document: what is held goes on, and what comes meanwhile is not held.
        remote.waiting = { [weak document] in document?.waitsForSettled ?? false }
        document.onSettledWait = { [weak remote] in remote?.release() }
        let launch = await sim.launch()
        #expect(launch.failure == nil, "\(String(describing: launch.failure))")
        await sim.settle()
        // Read in the turn settle() returned in: nothing may still be held or unanswered.
        let stillHeld = remote.holding, settled = document.isSettled, pending = document.pendingDescription
        // From here nothing is held: what is held goes on, and shutdown's own changes are not held.
        remote.waiting = { true }
        remote.release()
        #expect(remote.everHeld > 0, "no document change was held: the run did not place through the sidebar document")
        #expect(stillHeld == 0 && settled, "settle() returned with \(stillHeld) sidebar document changes still held (settled: \(settled); \(pending))")
        if stillHeld == 0 { try sim.verify(profile, classicBefore: before) }
        document.onSettledWait = nil
        await sim.shutdown()
    }
}
