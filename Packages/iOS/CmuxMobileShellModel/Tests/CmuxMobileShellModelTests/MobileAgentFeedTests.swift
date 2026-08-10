import Foundation
import Testing
@testable import CmuxMobileShellModel

struct MobileAgentFeedTests {
    @Test func unknownSourceKindAndStatusRemainInspectable() throws {
        let row = try decodeRow(
            id: "00000000-0000-0000-0000-000000000001",
            source: "future-agent",
            kind: "future-event",
            status: "future-status"
        )

        #expect(row.source == "future-agent")
        #expect(row.payload == .unknown(kind: "future-event"))
        #expect(row.status == .unknown("future-status"))
    }

    @Test func actionableRowsRequireAnExactRequestID() {
        #expect(throws: DecodingError.self) {
            try decodeRow(
                id: "00000000-0000-0000-0000-000000000002",
                kind: "permissionRequest",
                status: "pending"
            )
        }
    }

    @Test func permissionPayloadExposesOnlyTheRedactedSummary() throws {
        let row = try decodeRow(
            id: "00000000-0000-0000-0000-000000000003",
            kind: "permissionRequest",
            status: "pending",
            extra: "\"request_id\":\"request-3\",\"tool_name\":\"Bash\",\"tool_input\":\"secret-token\",\"tool_input_summary\":\"keys: command\",\"supported_modes\":[\"once\",\"deny\"]"
        )

        #expect(row.payload == .permission(
            requestID: "request-3",
            toolName: "Bash",
            safeInput: "keys: command",
            supportedModes: ["once", "deny"]
        ))
    }

    @Test func aggregationIsStableBoundedAndDeduplicated() throws {
        let oldest = try item(id: 1, mac: "mac-a", createdAt: "2026-08-09T10:00:00Z")
        let newest = try item(id: 2, mac: "mac-b", createdAt: "2026-08-09T12:00:00Z")
        let updatedWithoutReordering = try item(
            id: 1,
            mac: "mac-a",
            createdAt: "2026-08-09T10:00:00Z",
            updatedAt: "2026-08-09T13:00:00Z",
            status: "resolved"
        )

        let rows = MobileAgentFeedAggregation().items(from: [[oldest, newest], [updatedWithoutReordering]])

        #expect(rows.map(\.id) == [newest.id, updatedWithoutReordering.id])
        #expect(rows.last?.wire.status == .resolved(decision: nil))
    }

    @Test func needsInputBadgeProjectionCountsOnlyPendingRows() throws {
        let pending = try item(id: 4, mac: "mac-a", status: "pending", kind: "question", extra: "\"request_id\":\"request-4\",\"questions\":[]")
        let activity = try item(id: 5, mac: "mac-b")

        #expect(MobileAgentFeedFilter.needsInput.apply(to: [pending, activity]).map(\.id) == [pending.id])
        #expect(MobileAgentFeedFilter.allActivity.apply(to: [pending, activity]).count == 2)
    }

    @Test func aggregationCapsTwoThousandRowsAcrossTenAgents() throws {
        var snapshots: [[MobileAgentFeedItem]] = []
        for macIndex in 0..<10 {
            snapshots.append(try (0..<205).map { rowIndex in
                try item(id: macIndex * 205 + rowIndex + 10, mac: "mac-\(macIndex)")
            })
        }

        let rows = MobileAgentFeedAggregation().items(from: snapshots)

        #expect(rows.count == MobileAgentFeedAggregation.maxItemCount)
        #expect(Set(rows.map(\.macDeviceID)).count == 10)
    }

    private func item(
        id: Int,
        mac: String,
        createdAt: String = "2026-08-09T11:00:00Z",
        updatedAt: String? = nil,
        status: String = "telemetry",
        kind: String = "assistantMessage",
        extra: String = "\"text\":\"working\""
    ) throws -> MobileAgentFeedItem {
        let row = try decodeRow(
            id: String(format: "00000000-0000-0000-0000-%012d", id),
            kind: kind,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt ?? createdAt,
            extra: extra
        )
        return MobileAgentFeedItem(
            macDeviceID: mac,
            macInstanceTag: "dev",
            macDisplayName: mac,
            connectionStatus: .connected,
            wire: row
        )
    }

    private func decodeRow(
        id: String,
        source: String = "codex",
        kind: String = "assistantMessage",
        status: String = "telemetry",
        createdAt: String = "2026-08-09T11:00:00Z",
        updatedAt: String = "2026-08-09T11:00:00Z",
        extra: String? = "\"text\":\"working\""
    ) throws -> MobileWorkstreamFeedListItem {
        let suffix = extra.map { ",\($0)" } ?? ""
        let data = Data("""
        {"id":"\(id)","workstream_id":"agent-1","source":"\(source)","kind":"\(kind)","created_at":"\(createdAt)","updated_at":"\(updatedAt)","status":"\(status)"\(suffix)}
        """.utf8)
        return try JSONDecoder().decode(MobileWorkstreamFeedListItem.self, from: data)
    }
}
