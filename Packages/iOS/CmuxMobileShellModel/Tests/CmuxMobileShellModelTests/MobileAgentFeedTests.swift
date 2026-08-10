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

    @Test func rowPreservesExactWorkspaceAndSurfaceRoute() throws {
        let row = try decodeRow(
            id: "00000000-0000-0000-0000-000000000006",
            extra: "\"text\":\"working\",\"workspace_id\":\"workspace-exact\",\"surface_id\":\"surface-exact\""
        )

        #expect(row.workspaceID == "workspace-exact")
        #expect(row.surfaceID == "surface-exact")
    }

    @Test func legacyListResponseDefaultsToNoOlderHistory() throws {
        let data = Data("""
        {"revision":1,"items":[]}
        """.utf8)
        let response = try MobileWorkstreamFeedListResponse.decode(data)

        #expect(!response.hasMore)
        #expect(response.nextCursor == nil)
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

    @Test func perMacPagingMergesTwoPagesWithoutDuplicatesAndExhaustsIndependently() throws {
        let macAFirst = try response(ids: 301...600, revision: 1, cursor: "a-301", hasMore: true)
        let macASecond = try response(ids: 1...301, revision: 1, cursor: nil, hasMore: false)
        let macBFirst = try response(ids: 901...1_200, revision: 7, cursor: "b-901", hasMore: true)
        let macBSecond = try response(ids: 601...901, revision: 7, cursor: nil, hasMore: false)
        var macA = MobileAgentFeedPageAccumulator(response: macAFirst)
        var macB = MobileAgentFeedPageAccumulator(response: macBFirst)

        macA.append(macASecond)
        macB.append(macBSecond)

        #expect(macA.items.count == 600)
        #expect(macB.items.count == 600)
        #expect(Set(macA.items.map(\.id)).count == 600)
        #expect(Set(macB.items.map(\.id)).count == 600)
        #expect(!macA.hasMore && macA.nextCursor == nil)
        #expect(!macB.hasMore && macB.nextCursor == nil)

        let aggregated = MobileAgentFeedAggregation().items(from: [
            macA.items.map { mobileItem($0, mac: "mac-a") },
            macB.items.map { mobileItem($0, mac: "mac-b") },
        ])
        #expect(aggregated.count == 1_200)
        #expect(Set(aggregated.map(\.id)).count == 1_200)
        #expect(Set(aggregated.map(\.macDeviceID)) == ["mac-a", "mac-b"])
    }

    @Test func firstPageRefreshPreservesAlreadyLoadedOlderRows() throws {
        var pages = MobileAgentFeedPageAccumulator(
            response: try response(ids: 301...600, revision: 1, cursor: "301", hasMore: true)
        )
        pages.append(try response(ids: 1...301, revision: 1, cursor: nil, hasMore: false))
        pages.applyFirstPage(try response(ids: 302...601, revision: 2, cursor: "302", hasMore: true))

        #expect(pages.items.count == 601)
        #expect(Set(pages.items.map(\.id)).count == 601)
        #expect(!pages.hasMore)
        #expect(pages.nextCursor == nil)
    }

    @MainActor
    @Test func repeatedInvalidationsCoalesceAndLeaveNoRefreshTasks() async {
        let coalescer = MobileAgentFeedRefreshTaskCoalescer()
        var tasks: [Task<Void, Never>] = []
        for _ in 0..<100 {
            tasks.append(coalescer.schedule(ownerKey: "mac-a") {})
        }
        for task in tasks { await task.value }

        #expect(coalescer.activeCount == 0)
    }

    @Test func aggregationBenchmarkReportsIncreasingInputSizes() throws {
        for size in [300, 1_200, 2_400, 4_800] {
            var snapshots = Array(repeating: [MobileAgentFeedItem](), count: 12)
            for index in 0..<size {
                snapshots[index % snapshots.count].append(
                    try item(id: 20_000 + index, mac: "mac-\(index % snapshots.count)")
                )
            }
            let clock = ContinuousClock()
            let started = clock.now
            let output = MobileAgentFeedAggregation().items(from: snapshots)
            let elapsed = started.duration(to: clock.now)
            let components = elapsed.components
            let milliseconds = Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
            print("AGENT_FEED_AGGREGATION_BENCHMARK n=\(size) ms=\(milliseconds) output=\(output.count)")
            #expect(output.count == min(size, MobileAgentFeedAggregation.maxItemCount))
        }
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

    private func response(
        ids: ClosedRange<Int>,
        revision: UInt64,
        cursor: String?,
        hasMore: Bool
    ) throws -> MobileWorkstreamFeedListResponse {
        try MobileWorkstreamFeedListResponse(
            revision: revision,
            items: ids.map { index in
                try decodeRow(
                    id: String(format: "00000000-0000-0000-0000-%012d", index),
                    createdAt: "2026-08-09T11:\(String(format: "%02d", index % 60)):00Z",
                    updatedAt: "2026-08-09T11:\(String(format: "%02d", index % 60)):00Z"
                )
            },
            nextCursor: cursor,
            hasMore: hasMore
        )
    }

    private func mobileItem(_ wire: MobileWorkstreamFeedListItem, mac: String) -> MobileAgentFeedItem {
        MobileAgentFeedItem(
            macDeviceID: mac,
            macInstanceTag: "dev",
            macDisplayName: mac,
            connectionStatus: .connected,
            wire: wire
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
