@testable import CmuxNextApp
import CmuxNextSidebar
import Foundation
import Testing

/// The forced-order red for #28425: a classic import's slot moves go to the sidebar document
/// (`sidebar.apply`), and on a loaded runner their replies trail the run. Here every document change
/// and adopt sent in the first seconds is held before it reaches the daemon, longer than any quiet
/// window, as a slow one is there. The check must read the tree only once those moves have landed:
/// a settle that took a quiet tree for a done one read it while they were still held.
@MainActor @Suite(.serialized, .ownsSidebarDocStore, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ClassicUpgradeHeldDocumentTests {
    /// Holds each change and adopt before it is sent, from its first one until `hold` later, then sends
    /// them all in order and lets later ones through.
    @MainActor final class HeldRemote: SidebarDocRemote {
        private let inner: any SidebarDocRemote
        private let hold: Duration
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var timer: Task<Void, Never>?
        /// Changes and adopts that were held.
        private(set) var held = 0

        init(_ inner: any SidebarDocRemote, hold: Duration) {
            self.inner = inner
            self.hold = hold
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

        private func gate() async {
            guard !released else { return }
            held += 1
            // A fixture: the slow reply a loaded runner gives, longer than any quiet window. The code under test
            // must wait for the reply itself, whatever this is.
            if timer == nil {
                timer = Task { @MainActor [hold] in
                    try? await Task.sleep(for: hold)
                    self.release()
                }
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        private func release() {
            released = true
            let held = waiting
            waiting = []
            for change in held { change.resume() }
        }
    }

    @Test func theTreeIsReadOnlyOnceHeldDocumentMovesLand() async throws {
        let profile = ClassicUpgradeProfile.small
        let mac = try ClassicUpgradeSimulator.Mac()
        try mac.save(profile)
        let before = try mac.classicDigest()
        var remote: HeldRemote?
        let sim = try ClassicUpgradeSimulator(mac: mac) { inner in
            let held = HeldRemote(inner, hold: .seconds(4))
            remote = held
            return held
        }
        let held = try #require(remote, "the simulation did not make its sidebar document")
        let launch = await sim.launch()
        #expect(launch.failure == nil, "\(String(describing: launch.failure))")
        await sim.settle()
        // The run placed its workspaces through the document, and the check read only after those moves landed.
        #expect(held.held > 0, "no document change was held: the run did not place through the sidebar document")
        #expect(SidebarDocStore.current?.isSettled == true, "settle() returned while sidebar document changes were still held")
        try sim.verify(profile, classicBefore: before)
        await sim.shutdown()
    }
}
