import Foundation
import Testing
@testable import CmuxAgentJournal

/// The off switches: `agentMessages.enabled` (the store's `isEnabled`), a
/// surface opting out, and a workspace opting out. Each must refuse new
/// messages without storing them, stop delivery, and fail what was queued.
@Suite("Agent message off switch")
struct AgentMessageOffSwitchTests {
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-message-off-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("agent-messages.jsonl")
    }

    private func draft(
        to surface: String = "surface-b",
        workspace: String? = "workspace-b",
        body: String = "please rebase on main"
    ) -> AgentMessageDraft {
        AgentMessageDraft(
            senderName: "coordinator",
            senderSurfaceId: "surface-a",
            recipientSurfaceId: surface,
            recipientWorkspaceId: workspace,
            body: body
        )
    }

    // MARK: - App-wide switch

    @Test("With messages turned off, a send is refused and nothing is stored")
    func globalOffRefusesSend() throws {
        let enabled = Switch(false)
        let store = AgentMessageStore(fileURL: nil, isEnabled: { enabled.value })

        #expect(throws: AgentMessageBlockedError(block: .messagesDisabled)) {
            try store.append(draft())
        }
        #expect(store.messages(limit: .max).isEmpty)
        #expect(store.block(recipientSurfaceId: "surface-b", recipientWorkspaceId: nil) == .messagesDisabled)
    }

    @Test("Turning messages off stops delivery and fails what was queued")
    func globalOffFailsQueuedAndStopsDelivery() throws {
        let enabled = Switch(true)
        let seen = Changes()
        let store = AgentMessageStore(fileURL: nil, isEnabled: { enabled.value }, onChange: { seen.record($0) })
        let queued = try store.append(draft())
        #expect(store.poll(recipientSurfaceId: "surface-b", pollerKey: "hook", register: true) == .current(queued: 1))

        enabled.value = false

        // A hook checking in sees nothing and the message is failed, not
        // left queued.
        #expect(store.poll(recipientSurfaceId: "surface-b", pollerKey: "hook", register: false) == .current(queued: 0))
        #expect(store.claimQueued(recipientSurfaceId: "surface-b", via: "codex.stop").isEmpty)
        let failed = try #require(store.message(id: queued.id))
        #expect(failed.state == .failed)
        #expect(failed.failureReason == "messages_disabled")
        #expect(seen.states(for: queued.id) == [.queued, .failed])

        // Turning messages back on does not resurrect it.
        enabled.value = true
        #expect(store.claimQueued(recipientSurfaceId: "surface-b", via: "codex.stop").isEmpty)
        #expect(store.markRead(ids: [queued.id]).isEmpty)
        #expect(store.message(id: queued.id)?.state == .failed)
    }

    @Test("A sweep fails queued messages for every recipient but leaves ones a wake hook already showed")
    func sweepSkipsLeasedMessages() throws {
        let enabled = Switch(true)
        let store = AgentMessageStore(fileURL: nil, isEnabled: { enabled.value })
        let leased = try store.append(draft())
        let other = try store.append(draft(to: "surface-c", workspace: "workspace-c"))
        _ = store.poll(recipientSurfaceId: "surface-b", pollerKey: "wake", register: true)
        let lease = try #require(store.deferredMessages(recipientSurfaceId: "surface-b", pollerKey: "wake"))
        #expect(lease.messages.map(\.id) == [leased.id])

        enabled.value = false
        let failed = store.failBlockedQueued()

        // The wake hook has printed the leased message, so the sweep leaves
        // it for the hook's acknowledgement, which records it delivered.
        #expect(failed.map(\.id) == [other.id])
        #expect(store.message(id: leased.id)?.state == .queued)
        let acknowledged = store.acknowledgeDeferredLease(
            id: lease.id,
            recipientSurfaceId: "surface-b",
            pollerKey: "wake",
            via: "claude.wake"
        )
        #expect(acknowledged.map(\.id) == [leased.id])
        #expect(store.message(id: leased.id)?.state == .delivered)
        #expect(store.messages(states: [.queued], limit: .max).isEmpty)
    }

    @Test("A leased message whose lease expires unacknowledged fails at the next sweep")
    func expiredLeaseFailsAtNextSweep() throws {
        let enabled = Switch(true)
        let clock = TestClock()
        let store = AgentMessageStore(fileURL: nil, now: { clock.now }, isEnabled: { enabled.value })
        let leased = try store.append(draft())
        _ = store.poll(recipientSurfaceId: "surface-b", pollerKey: "wake", register: true)
        _ = try #require(store.deferredMessages(recipientSurfaceId: "surface-b", pollerKey: "wake"))

        enabled.value = false
        #expect(store.failBlockedQueued().isEmpty)
        clock.advance(by: AgentMessageStore.deferredLeaseLifetime + 1)
        #expect(store.failBlockedQueued().map(\.id) == [leased.id])
        #expect(store.message(id: leased.id)?.failureReason == "messages_disabled")
    }

    @Test("A switch turned off just before a claim takes the lock fails the message instead of delivering it")
    func toggleBeforeClaimLockFails() throws {
        let enabled = Switch(true)
        let store = AgentMessageStore(fileURL: nil, isEnabled: { enabled.value })
        let queued = try store.append(draft())
        // The old claim swept, released the lock, then delivered; a toggle
        // landing in that gap was delivered anyway.
        _ = store.failBlockedQueued(recipientSurfaceId: "surface-b")
        store.beforeDeliveryLockForTesting = { enabled.value = false }

        #expect(store.claimQueued(recipientSurfaceId: "surface-b", via: "codex.stop").isEmpty)
        #expect(store.message(id: queued.id)?.state == .failed)
        #expect(store.message(id: queued.id)?.failureReason == "messages_disabled")
    }

    @Test("A switch turned off just before a wake lease is built keeps the message out of the lease")
    func toggleBeforeLeaseLockFails() throws {
        let enabled = Switch(true)
        let seen = Changes()
        let store = AgentMessageStore(fileURL: nil, isEnabled: { enabled.value }, onChange: { seen.record($0) })
        let queued = try store.append(draft())
        _ = store.poll(recipientSurfaceId: "surface-b", pollerKey: "wake", register: true)
        store.beforeDeliveryLockForTesting = { enabled.value = false }

        let lease = try #require(store.deferredMessages(recipientSurfaceId: "surface-b", pollerKey: "wake"))

        #expect(lease.messages.isEmpty)
        #expect(store.message(id: queued.id)?.state == .failed)
        #expect(seen.states(for: queued.id) == [.queued, .failed])
    }

    // MARK: - Per surface

    @Test("Only a queued message can fail; one already shown stays delivered or read")
    func onlyQueuedCanFail() {
        #expect(AgentMessageDeliveryState.queued.canAdvance(to: .failed))
        #expect(!AgentMessageDeliveryState.delivered.canAdvance(to: .failed))
        #expect(!AgentMessageDeliveryState.read.canAdvance(to: .failed))
        #expect(!AgentMessageDeliveryState.failed.canAdvance(to: .read))
        #expect(AgentMessageDeliveryState.delivered.canAdvance(to: .read))
    }

    @Test("A surface that turned messages off refuses new ones and fails its queue")
    func surfaceOptOut() throws {
        let store = AgentMessageStore(fileURL: nil)
        let queued = try store.append(draft())
        let elsewhere = try store.append(draft(to: "surface-c", workspace: "workspace-b"))

        let failed = try store.setReceivingEnabled(false, scope: .surface, id: "surface-b")

        #expect(failed.map(\.id) == [queued.id])
        #expect(store.message(id: queued.id)?.failureReason == "recipient_disabled")
        #expect(store.message(id: elsewhere.id)?.state == .queued)
        #expect(throws: AgentMessageBlockedError(block: .recipientDisabled(surfaceId: "surface-b"))) {
            try store.append(draft(body: "another"))
        }
        #expect(store.messages(limit: .max).count == 2)
        #expect(store.isReceivingDisabled(scope: .surface, id: "surface-b"))

        try store.setReceivingEnabled(true, scope: .surface, id: "surface-b")
        let accepted = try store.append(draft(body: "welcome back"))
        #expect(accepted.state == .queued)
        #expect(store.message(id: queued.id)?.state == .failed)
    }

    // MARK: - Per workspace

    @Test("A workspace that turned messages off covers every surface in it")
    func workspaceOptOut() throws {
        let store = AgentMessageStore(fileURL: nil)
        let queued = try store.append(draft(to: "surface-c", workspace: "workspace-b"))

        try store.setReceivingEnabled(false, scope: .workspace, id: "workspace-b")

        #expect(store.message(id: queued.id)?.failureReason == "workspace_disabled")
        #expect(throws: AgentMessageBlockedError(block: .workspaceDisabled(workspaceId: "workspace-b"))) {
            try store.append(draft(to: "surface-d", workspace: "workspace-b"))
        }
        let otherWorkspace = try store.append(draft(to: "surface-e", workspace: "workspace-c"))
        #expect(otherWorkspace.state == .queued)
    }

    @Test("Stored opt-outs are capped; the oldest is dropped first")
    func optOutsAreBounded() throws {
        let store = AgentMessageStore(fileURL: nil)
        for index in 0...AgentMessageStore.retainedOptOutCount {
            try store.setReceivingEnabled(false, scope: .surface, id: "surface-\(index)")
        }
        #expect(!store.isReceivingDisabled(scope: .surface, id: "surface-0"))
        #expect(store.isReceivingDisabled(scope: .surface, id: "surface-1"))
        #expect(store.isReceivingDisabled(scope: .surface, id: "surface-\(AgentMessageStore.retainedOptOutCount)"))
    }

    @Test("A full store drops an opt-out for something closed before one still open, and replay agrees")
    func evictionPrefersClosedRecipients() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AgentMessageStore(fileURL: url)
        let cap = AgentMessageStore.retainedOptOutCount
        for index in 0..<cap {
            try store.setReceivingEnabled(false, scope: .surface, id: "surface-\(index)")
        }
        #expect(store.isAtOptOutCapacity)
        // surface-0 and surface-1 are still open; surface-2 has closed.
        let open = AgentMessageOpenRecipients(
            surfaceIds: Set((0..<cap).map { "surface-\($0)" }).subtracting(["surface-2"]),
            workspaceIds: []
        )

        try store.setReceivingEnabled(false, scope: .surface, id: "surface-new", openRecipients: open)

        #expect(store.isReceivingDisabled(scope: .surface, id: "surface-0"))
        #expect(!store.isReceivingDisabled(scope: .surface, id: "surface-2"))
        #expect(store.isReceivingDisabled(scope: .surface, id: "surface-new"))
        let reopened = AgentMessageStore(fileURL: url)
        #expect(reopened.isReceivingDisabled(scope: .surface, id: "surface-0"))
        #expect(!reopened.isReceivingDisabled(scope: .surface, id: "surface-2"))
        #expect(reopened.isReceivingDisabled(scope: .surface, id: "surface-new"))
    }

    @Test("Toggling an opt-out many times keeps the journal file small")
    func repeatedTogglesStayBounded() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AgentMessageStore(fileURL: url)
        for _ in 0..<(AgentMessageStore.compactionThreshold * 2) {
            try store.setReceivingEnabled(false, scope: .surface, id: "surface-b")
            try store.setReceivingEnabled(true, scope: .surface, id: "surface-b")
        }
        try store.setReceivingEnabled(false, scope: .surface, id: "surface-b")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count < AgentMessageStore.compactionThreshold)
        #expect(AgentMessageStore(fileURL: url).isReceivingDisabled(scope: .surface, id: "surface-b"))
    }

    // MARK: - Persistence

    @Test("Opt-outs and failed messages survive reopening and compaction")
    func optOutsPersist() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let failedID: String
        do {
            let store = AgentMessageStore(fileURL: url)
            failedID = try store.append(draft()).id
            try store.setReceivingEnabled(false, scope: .surface, id: "surface-b")
            try store.setReceivingEnabled(false, scope: .workspace, id: "workspace-z")
        }

        let reopened = AgentMessageStore(fileURL: url)
        #expect(reopened.message(id: failedID)?.state == .failed)
        #expect(reopened.message(id: failedID)?.failureReason == "recipient_disabled")
        #expect(reopened.isReceivingDisabled(scope: .surface, id: "surface-b"))
        #expect(reopened.isReceivingDisabled(scope: .workspace, id: "workspace-z"))

        // Push the file past the compaction threshold; the opt-outs remain.
        for index in 0...AgentMessageStore.compactionThreshold {
            let message = try reopened.append(draft(to: "surface-c", workspace: nil, body: "message \(index)"))
            _ = reopened.markRead(ids: [message.id])
        }
        let compacted = AgentMessageStore(fileURL: url)
        #expect(compacted.messages(limit: .max).count <= AgentMessageStore.retainedMessageCount + 1)
        #expect(compacted.isReceivingDisabled(scope: .surface, id: "surface-b"))
        #expect(compacted.isReceivingDisabled(scope: .workspace, id: "workspace-z"))
    }
}

private final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Bool

    init(_ value: Bool) {
        current = value
    }

    var value: Bool {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }
}

private final class Changes: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [AgentMessageStoreChange] = []

    func record(_ change: AgentMessageStoreChange) {
        lock.withLock { changes.append(change) }
    }

    func states(for id: String) -> [AgentMessageDeliveryState] {
        lock.withLock { changes.filter { $0.message.id == id }.map(\.state) }
    }
}
