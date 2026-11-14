import Foundation
import Testing

@testable import CmuxSidebar

@Suite("CustomSidebarAgentBindingIndex")
struct CustomSidebarAgentBindingIndexTests {
    private struct Record: Equatable {
        let id: Int
        let surfaceID: String?
        let workspaceID: String?
    }

    private struct Workspace {
        let id: String
        let panelIds: [UUID]
    }

    private static func binding(_ record: Record) -> CustomSidebarAgentBindingIndex<Record>.Binding {
        if let panelId = record.surfaceID.flatMap(UUID.init(uuidString:)) {
            return .panel(panelId)
        }
        return record.workspaceID.map { .workspace($0) } ?? .unbound
    }

    /// The per-workspace scan the index replaces, kept as the oracle.
    private static func scan(_ records: [Record], workspace: Workspace, limit: Int) -> [Record] {
        let panels = Set(workspace.panelIds)
        var kept: [Record] = []
        for record in records {
            if let panelId = record.surfaceID.flatMap(UUID.init(uuidString:)) {
                guard panels.contains(panelId) else { continue }
            } else {
                guard record.workspaceID == workspace.id else { continue }
            }
            kept.append(record)
            if kept.count >= limit { break }
        }
        return kept
    }

    @Test("matches the per-workspace scan on mixed bindings")
    func matchesScan() {
        var generator = SplitMix64(seed: 0x5EED)
        let workspaces = (0..<12).map { index in
            Workspace(
                id: UUID().uuidString,
                panelIds: (0..<(index % 4)).map { _ in UUID() }
            )
        }
        let allPanels = workspaces.flatMap(\.panelIds) + (0..<5).map { _ in UUID() }
        let records: [Record] = (0..<600).map { id in
            let workspaceID: String? = generator.next() % 5 == 0
                ? nil
                : workspaces[Int(generator.next() % UInt64(workspaces.count))].id
            let surfaceID: String?
            switch generator.next() % 4 {
            case 0: surfaceID = nil
            case 1: surfaceID = "not-a-uuid"
            default: surfaceID = allPanels[Int(generator.next() % UInt64(allPanels.count))].uuidString
            }
            return Record(id: id, surfaceID: surfaceID, workspaceID: workspaceID)
        }
        let index = CustomSidebarAgentBindingIndex(records: records, binding: Self.binding)
        for workspace in workspaces {
            for limit in [1, 3, 24, 1_000] {
                let indexed = index.records(panelIds: workspace.panelIds, workspaceId: workspace.id, limit: limit)
                    .map(\.record)
                #expect(indexed == Self.scan(records, workspace: workspace, limit: limit))
            }
        }
    }

    @Test("a panel binding wins over a matching stored workspace id")
    func panelBindingIsAuthoritative() {
        let here = Workspace(id: "here", panelIds: [UUID()])
        let elsewhere = UUID()
        let records = [
            Record(id: 0, surfaceID: elsewhere.uuidString, workspaceID: "here"),
            Record(id: 1, surfaceID: here.panelIds[0].uuidString, workspaceID: "stale"),
            Record(id: 2, surfaceID: nil, workspaceID: "here"),
        ]
        let index = CustomSidebarAgentBindingIndex(records: records, binding: Self.binding)
        let matches = index.records(panelIds: here.panelIds, workspaceId: here.id, limit: 24)
        #expect(matches.map(\.record.id) == [1, 2])
        #expect(matches.map(\.panelId) == [here.panelIds[0], nil])
    }

    @Test("an empty index and a zero limit return nothing")
    func emptyCases() {
        let empty = CustomSidebarAgentBindingIndex<Record>()
        #expect(empty.records(panelIds: [UUID()], workspaceId: "w", limit: 24).isEmpty)
        let index = CustomSidebarAgentBindingIndex(
            records: [Record(id: 0, surfaceID: nil, workspaceID: "w")],
            binding: Self.binding
        )
        #expect(index.records(panelIds: [], workspaceId: "w", limit: 0).isEmpty)
    }
}

/// A small seeded generator, so the mixed-binding test is reproducible.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
