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

    @Test func booleanAndFormPrimitivesDecodeIntoInlinePayloads() throws {
        let boolean = try decodeRow(
            id: "00000000-0000-0000-0000-000000000009",
            kind: "boolean",
            status: "pending",
            extra: "\"request_id\":\"bool-9\",\"boolean_prompt\":\"Continue?\",\"boolean_yes_label\":\"Continue\",\"boolean_no_label\":\"Stop\",\"boolean_default\":true,\"questions\":[{\"id\":\"q0\",\"prompt\":\"Continue?\",\"multi_select\":false,\"input_type\":\"boolean\",\"options\":[{\"id\":\"yes\",\"label\":\"Continue\"},{\"id\":\"no\",\"label\":\"Stop\"}]}]"
        )
        #expect(boolean.payload == .boolean(
            requestID: "bool-9",
            prompt: "Continue?",
            yesLabel: "Continue",
            noLabel: "Stop",
            defaultValue: true
        ))

        let form = try decodeRow(
            id: "00000000-0000-0000-0000-000000000010",
            kind: "form",
            status: "pending",
            extra: "\"request_id\":\"form-10\",\"form_title\":\"Release\",\"form_url\":\"https://example.com/form\",\"questions\":[{\"id\":\"branch\",\"prompt\":\"Branch\",\"multi_select\":false,\"input_type\":\"text\",\"required\":true,\"min_length\":2,\"max_length\":20},{\"id\":\"targets\",\"prompt\":\"Targets\",\"multi_select\":true,\"input_type\":\"choice\",\"min_selections\":1,\"max_selections\":2,\"options\":[{\"id\":\"ios\",\"label\":\"iOS\"}]}]"
        )
        guard case .form(let requestID, let title, let fields, let externalURL) = form.payload else {
            Issue.record("Expected form payload")
            return
        }
        #expect(requestID == "form-10")
        #expect(title == "Release")
        #expect(fields.first?.inputType == "text")
        #expect(fields.first?.minLength == 2)
        #expect(fields.first?.maxLength == 20)
        #expect(fields.last?.minSelections == 1)
        #expect(fields.last?.maxSelections == 2)
        #expect(externalURL == "https://example.com/form")
    }

    @Test func resolvedFormActionRemainsInspectable() throws {
        let row = try decodeRow(
            id: "00000000-0000-0000-0000-000000000012",
            source: "codex",
            kind: "form",
            status: "resolved",
            extra: "\"request_id\":\"form-12\",\"questions\":[],\"decision\":{\"kind\":\"form\",\"action\":\"decline\",\"selections\":[]}"
        )
        #expect(row.status == .resolved(decision: .form(action: "decline", selections: [])))
    }

    @Test func appServerQuestionAliasesAndOtherMetadataDecode() throws {
        let row = try decodeRow(
            id: "00000000-0000-0000-0000-000000000011",
            kind: "item/tool/requestUserInput",
            status: "pending",
            extra: "\"request_id\":\"codex-11\",\"questions\":[{\"id\":\"mode\",\"header\":\"Mode\",\"question\":\"Choose\",\"is_other\":false,\"options\":[{\"label\":\"Fast\",\"description\":\"Quick\"}]}]"
        )
        guard case .question(let requestID, let questions) = row.payload else {
            Issue.record("Expected question payload")
            return
        }
        #expect(requestID == "codex-11")
        #expect(questions.first?.allowsOther == false)
        #expect(questions.first?.options.first?.id == "Fast")
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

    @Test func needsInputProjectionIncludesPendingDecisionsAndLatestCompletedTurns() throws {
        let pending = try item(id: 4, mac: "mac-a", status: "pending", kind: "question", extra: "\"request_id\":\"request-4\",\"questions\":[]")
        let activity = try item(id: 5, mac: "mac-b")
        let stoppedTurn = try item(
            id: 6,
            mac: "mac-c",
            kind: "stop",
            extra: "\"reason\":\"Waiting for the next instruction\""
        )
        let endedSession = try item(
            id: 7,
            mac: "mac-d",
            kind: "sessionEnd",
            extra: "\"reason\":null"
        )
        let resumedTurn = try item(
            id: 8,
            mac: "mac-c",
            createdAt: "2026-08-09T12:00:00Z"
        )

        let items = [resumedTurn, pending, activity, stoppedTurn, endedSession]

        #expect(
            MobileAgentFeedFilter.needsInput.apply(to: items).map(\.id)
                == [pending.id, endedSession.id]
        )
        #expect(MobileAgentFeedFilter.allActivity.apply(to: items).count == 5)
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

    @Test func pagingStopsAtPhoneHistoryLimitWithoutRequestingDiscardedRows() throws {
        var oldestLoadedID = 2_101
        var requestCount = 1
        var pages = MobileAgentFeedPageAccumulator(
            response: try hostResponse(ids: oldestLoadedID...2_400)
        )

        while pages.hasMore {
            let pageOldestID = oldestLoadedID - 300
            pages.append(try hostResponse(ids: pageOldestID...(oldestLoadedID - 1)))
            oldestLoadedID = pageOldestID
            requestCount += 1
        }

        #expect(requestCount == 7)
        #expect(pages.items.count == MobileAgentFeedAggregation.maxItemCount)
        #expect(Set(pages.items.map(\.id)).count == MobileAgentFeedAggregation.maxItemCount)
        let expectedIDs = Set((401...2_400).compactMap { UUID(uuidString: feedItemID($0)) })
        #expect(Set(pages.items.map(\.id)) == expectedIDs)
        #expect(pages.reachedHistoryLimit)
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

    @MainActor
    @Test func invalidationDuringRefreshRunsOneTrailingRefresh() async {
        let coalescer = MobileAgentFeedRefreshTaskCoalescer()
        let gate = AgentFeedRefreshGate()
        var refreshCount = 0
        let first = coalescer.schedule(ownerKey: "mac-a") {
            refreshCount += 1
            await gate.wait()
        }
        await Task.yield()
        let trailing = coalescer.schedule(ownerKey: "mac-a") {
            refreshCount += 1
        }
        #expect(coalescer.activeCount == 1)
        await gate.release()
        await first.value
        await trailing.value

        #expect(refreshCount == 2)
        #expect(coalescer.activeCount == 0)
    }

    @MainActor
    @Test func cancellingOwnerDropsItsPendingTrailingRefresh() async {
        let coalescer = MobileAgentFeedRefreshTaskCoalescer()
        let gate = AgentFeedRefreshGate()
        var trailingRuns = 0
        let first = coalescer.schedule(ownerKey: "mac-a") { await gate.wait() }
        await Task.yield()
        _ = coalescer.schedule(ownerKey: "mac-a") { trailingRuns += 1 }

        coalescer.cancel(ownerKey: "mac-a")
        await gate.release()
        await first.value

        #expect(trailingRuns == 0)
        #expect(coalescer.activeCount == 0)
    }

    @Test func aggregationBenchmarkReportsIncreasingInputSizes() throws {
        var elapsedBySize: [Int: Double] = [:]
        for size in [300, 1_200, 2_400, 4_800] {
            var snapshots = Array(repeating: [MobileAgentFeedItem](), count: 12)
            for index in 0..<size {
                snapshots[index % snapshots.count].append(
                    try item(id: 20_000 + index, mac: "mac-\(index % snapshots.count)")
                )
            }
            let clock = ContinuousClock()
            let started = clock.now
            var output: [MobileAgentFeedItem] = []
            for _ in 0..<30 {
                output = MobileAgentFeedAggregation().items(from: snapshots)
            }
            let elapsed = started.duration(to: clock.now)
            let components = elapsed.components
            let milliseconds = Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
            elapsedBySize[size] = milliseconds
            print("AGENT_FEED_AGGREGATION_BENCHMARK n=\(size) runs=30 ms=\(milliseconds) output=\(output.count)")
            #expect(output.count == min(size, MobileAgentFeedAggregation.maxItemCount))
        }
        let baseline = try #require(elapsedBySize[1_200])
        let doubledTwice = try #require(elapsedBySize[4_800])
        #expect(
            doubledTwice < baseline * 8,
            "4x input must remain below 8x runtime; quadratic growth approaches 16x"
        )
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

    private func hostResponse(ids: ClosedRange<Int>) throws -> MobileWorkstreamFeedListResponse {
        let formatter = ISO8601DateFormatter()
        return try MobileWorkstreamFeedListResponse(
            revision: 1,
            items: ids.map { index in
                let timestamp = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(index)))
                return try decodeRow(
                    id: feedItemID(index),
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            },
            nextCursor: ids.lowerBound > 1 ? String(ids.lowerBound - 1) : nil,
            hasMore: ids.lowerBound > 1
        )
    }

    private func feedItemID(_ index: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012d", index)
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

private actor AgentFeedRefreshGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}
