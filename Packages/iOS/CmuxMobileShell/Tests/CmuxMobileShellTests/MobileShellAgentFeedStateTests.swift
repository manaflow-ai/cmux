@testable import CmuxMobileShell
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing

@MainActor
@Suite("Mobile shell agent feed state")
struct MobileShellAgentFeedStateTests {
    private func response(
        revision: Int,
        rows: [[String: Any]]
    ) throws -> MobileAgentFeedListResponse {
        let payload: [String: Any] = ["revision": revision, "items": rows]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try MobileAgentFeedListResponse.decode(data)
    }

    private func row(
        id: String,
        kind: String = "permissionRequest",
        status: String = "pending",
        requestID: String? = "req-\(UUID().uuidString.prefix(6))",
        createdAt: String = "2026-08-14T10:00:00Z",
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var row: [String: Any] = [
            "id": id,
            "workstream_id": "claude-s1",
            "source": "claude",
            "kind": kind,
            "status": status,
            "created_at": createdAt,
            "updated_at": createdAt,
        ]
        if let requestID {
            row["request_id"] = requestID
        }
        for (key, value) in extra {
            row[key] = value
        }
        return row
    }

    @Test("Snapshots apply newest-first with revision guards")
    func revisionGuards() throws {
        let store = MobileShellComposite()

        #expect(store.applyAgentFeedSnapshot(
            try response(revision: 2, rows: [
                row(id: "old", createdAt: "2026-08-14T09:00:00Z"),
                row(id: "new", createdAt: "2026-08-14T11:00:00Z"),
            ]),
            macDeviceID: "mac-a",
            displayName: "Desk Mac"
        ))
        #expect(store.agentFeedItems.map(\.itemID) == ["new", "old"])
        #expect(store.agentFeedSnapshotsByMac["mac-a"]?.revision == 2)

        // A response older than the known revision is rejected and re-arms
        // a trailing refresh.
        store.agentFeedKnownRevisionsByMac["mac-a"] = 5
        #expect(!store.applyAgentFeedSnapshot(
            try response(revision: 4, rows: [row(id: "stale")]),
            macDeviceID: "mac-a",
            displayName: "Desk Mac"
        ))
        #expect(store.agentFeedRefreshPendingMacIDs.contains("mac-a"))
        #expect(store.agentFeedItems.map(\.itemID) == ["new", "old"])

        #expect(store.applyAgentFeedSnapshot(
            try response(revision: 5, rows: [row(id: "current")]),
            macDeviceID: "mac-a",
            displayName: "Desk Mac"
        ))
        #expect(store.agentFeedItems.map(\.itemID) == ["current"])
    }

    @Test("Needs-input badge counts pending actionable rows across Macs")
    func needsInputCount() throws {
        let store = MobileShellComposite()
        #expect(store.applyAgentFeedSnapshot(
            try response(revision: 1, rows: [
                row(id: "q", kind: "question", extra: [
                    "questions": [[
                        "id": "q1",
                        "prompt": "Which route?",
                        "multi_select": false,
                        "options": [["id": "o1", "label": "A"]],
                    ]],
                ]),
                row(id: "resolved", status: "resolved", extra: [
                    "decision": ["kind": "permission", "mode": "once"],
                ]),
                row(id: "telemetry", kind: "toolUse", status: "telemetry", requestID: nil),
            ]),
            macDeviceID: "mac-a",
            displayName: "Desk Mac"
        ))
        #expect(store.agentFeedItems.count == 3)
        #expect(store.agentFeedNeedsInputCount == 1)
        let question = try #require(store.agentFeedItems.first { $0.itemID == "q" })
        #expect(question.questions.first?.options.first?.label == "A")
    }

    @Test("Local resolution flips the pending row and survives recompute")
    func localResolution() throws {
        let store = MobileShellComposite()
        #expect(store.applyAgentFeedSnapshot(
            try response(revision: 1, rows: [
                row(id: "p", requestID: "req-77"),
            ]),
            macDeviceID: "mac-a",
            displayName: "Desk Mac"
        ))
        #expect(store.agentFeedNeedsInputCount == 1)

        store.applyAgentFeedLocalResolution(
            ownerKey: "mac-a",
            requestID: "req-77",
            decision: MobileAgentFeedDecision(kind: "permission", mode: "deny")
        )
        #expect(store.agentFeedNeedsInputCount == 0)
        let item = try #require(store.agentFeedItems.first)
        guard case .resolved(let decision) = item.status else {
            Issue.record("expected resolved status")
            return
        }
        #expect(decision.mode == "deny")
    }

    @Test("Sibling pairings keep separate rows under tagged owner keys")
    func taggedOwnerKeysStaySeparate() throws {
        let store = MobileShellComposite()
        let nightlyKey = "mac-a\u{1F}nightly"
        let stableKey = "mac-a\u{1F}default"

        #expect(store.applyAgentFeedSnapshot(
            try response(revision: 3, rows: [row(id: "shared-id")]),
            macDeviceID: nightlyKey,
            displayName: "Desk Mac"
        ))
        #expect(store.applyAgentFeedSnapshot(
            try response(revision: 5, rows: [row(id: "shared-id")]),
            macDeviceID: stableKey,
            displayName: "Desk Mac"
        ))
        #expect(store.agentFeedItems.count == 2)
        #expect(store.agentFeedSnapshotsByMac[nightlyKey]?.revision == 3)
        #expect(store.agentFeedSnapshotsByMac[stableKey]?.revision == 5)
        #expect(Set(store.agentFeedItems.map(\.macDeviceID)) == ["mac-a"])
    }

    @Test("Malformed rows are dropped without failing the snapshot")
    func malformedRowsDropped() throws {
        let store = MobileShellComposite()
        #expect(store.applyAgentFeedSnapshot(
            try response(revision: 1, rows: [
                row(id: "good"),
                ["id": "missing-everything"],
            ]),
            macDeviceID: "mac-a",
            displayName: "Desk Mac"
        ))
        #expect(store.agentFeedItems.map(\.itemID) == ["good"])
    }

    @Test("Reset clears rows, revisions, and pending replies")
    func reset() throws {
        let store = MobileShellComposite()
        #expect(store.applyAgentFeedSnapshot(
            try response(revision: 9, rows: [row(id: "x")]),
            macDeviceID: "mac-a",
            displayName: "Desk Mac"
        ))
        store.agentFeedPendingReplyRequestIDs.insert("req-1")
        store.resetAgentFeed()
        #expect(store.agentFeedItems.isEmpty)
        #expect(store.agentFeedSnapshotsByMac.isEmpty)
        #expect(store.agentFeedKnownRevisionsByMac.isEmpty)
        #expect(store.agentFeedPendingReplyRequestIDs.isEmpty)
        #expect(store.agentFeedNeedsInputCount == 0)
    }
}
