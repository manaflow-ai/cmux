import Foundation
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

/// The Cloud migration is one shared store mutation: two windows showing the
/// same legacy section must not send two optimistic `section.update`s while
/// the first is awaiting its daemon outcome, but a refusal must allow retry.
@MainActor @Suite struct SidebarDocHostGroupMigrationTests {
    @Test func aPendingMigrationIsSentOnceThenRetriesAfterRefusal() async throws {
        let remote = HostGroupRefusingRemote()
        let store = SidebarDocStore(remote: remote)
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        try #require(store.isActive, "the host-group test document did not load")

        store.markHostGroup(session: "mini", title: "Cloud machine")
        store.markHostGroup(session: "mini", title: "Cloud machine")
        await remote.waitForFirstApply()
        #expect(remote.applyCount == 1)

        let refused = HostGroupSignal()
        store.onRefused = { _ in refused.signal() }
        remote.releaseFirstApply()
        await refused.wait()

        store.markHostGroup(session: "mini", title: "Cloud machine")
        await remote.waitForSecondApply()
        #expect(remote.applyCount == 2)
    }
}

@MainActor private final class HostGroupRefusingRemote: SidebarDocRemote {
    private struct Refused: Error {}
    var applyCount = 0
    var isAvailable: Bool { true }
    private var firstApplyStarted: CheckedContinuation<Void, Never>?
    private var firstApplyRelease: CheckedContinuation<Void, Never>?
    private var firstApplyReleased = false
    private var secondApplyStarted: CheckedContinuation<Void, Never>?
    private(set) var documentHostGrouped = false

    func waitForFirstApply() async {
        if applyCount >= 1 { return }
        await withCheckedContinuation { firstApplyStarted = $0 }
    }

    func releaseFirstApply() {
        firstApplyReleased = true
        if let firstApplyRelease {
            self.firstApplyRelease = nil
            firstApplyRelease.resume()
        }
    }

    func waitForSecondApply() async {
        if applyCount >= 2 { return }
        await withCheckedContinuation { secondApplyStarted = $0 }
    }

    func get() async throws -> Data {
        let hostGroup = documentHostGrouped ? #", "host_group": true"# : ""
        return Data(#"{"revision":"1","sections":[{"id":"sec_m_mini","kind":{"type":"machine","session_id":"mini"}"# + hostGroup + #"}],"items":[]}"#.utf8)
    }

    func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { try await refused() }
    func pin(_ items: [String], key: String) async throws -> SidebarDocReply { try await refused() }
    func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { try await refused() }
    func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { try await refused() }

    func apply(ops: Data, key: String) async throws -> SidebarDocReply {
        applyCount += 1
        if applyCount == 1 {
            firstApplyStarted?.resume()
            firstApplyStarted = nil
            if firstApplyReleased {
                firstApplyReleased = false
            } else {
                await withCheckedContinuation { firstApplyRelease = $0 }
            }
            throw Refused()
        }
        documentHostGrouped = true
        secondApplyStarted?.resume()
        secondApplyStarted = nil
        return SidebarDocReply(revision: nil, inverse: Data("[]".utf8))
    }

    private func refused() async throws -> SidebarDocReply { throw Refused() }
}

@MainActor private final class HostGroupSignal {
    private var signaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        if let continuation {
            self.continuation = nil
            continuation.resume()
        } else {
            signaled = true
        }
    }

    func wait() async {
        if signaled {
            signaled = false
            return
        }
        await withCheckedContinuation { continuation = $0 }
    }
}
