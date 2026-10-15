import CmuxNextDesign
import CmuxNextSettings
import Testing

/// Group by Status is a Labs look (`labs.sidebarStatusGrouping`): until a person turns it on,
/// `sidebar.groupBy: "status"` reads as no grouping, and the child-session elbow
/// (`labs.sidebarStatusElbow`) draws only with status grouping's flag on too.
struct SidebarStatusGroupingLabsTests {
    private func sections(groupBy: String? = nil, grouping: Bool? = nil, elbow: Bool? = nil) -> (CmuxConfigSnapshot, SidebarSectionsPreferences) {
        var root: [String: JSONValue] = [:]
        if let groupBy { root["sidebar"] = .object(["groupBy": .string(groupBy)]) }
        var labs: [String: JSONValue] = [:]
        if let grouping { labs["sidebarStatusGrouping"] = .bool(grouping) }
        if let elbow { labs["sidebarStatusElbow"] = .bool(elbow) }
        if !labs.isEmpty { root["labs"] = .object(labs) }
        let snapshot = CmuxConfigSnapshot.parse(.object(root), validDensities: [], validMetrics: [])
        return (snapshot, snapshot.sidebarSections)
    }

    @Test func bothFlagsAreOffByDefault() {
        let (snapshot, prefs) = sections()
        #expect(!snapshot.lab(.sidebarStatusGrouping, teamBuild: true))
        #expect(!snapshot.lab(.sidebarStatusElbow, teamBuild: true))
        #expect(prefs.groupBy == .none)
        #expect(!prefs.statusElbow)
    }

    @Test func statusReadsAsNoGroupingUntilTheFlagIsOn() {
        let off = sections(groupBy: "status").1
        #expect(off.groupBy == .none)
        #expect(sections(groupBy: "status", grouping: false).1.groupBy == .none)
        #expect(sections(groupBy: "status", grouping: true).1.groupBy == .status)
        // The flag changes only `status`: folder grouping reads the same either way, and the
        // value is valid, so it leaves no diagnostic.
        #expect(sections(groupBy: "folder").1.groupBy == .folder)
        #expect(sections(groupBy: "folder", grouping: true).1.groupBy == .folder)
        #expect(!sections(groupBy: "status").0.diagnostics.contains { $0.path == "sidebar.groupBy" })
    }

    @Test func theElbowNeedsStatusGroupingsFlag() {
        #expect(!sections(elbow: true).1.statusElbow)
        #expect(!sections(groupBy: "status", elbow: true).1.statusElbow)
        #expect(sections(groupBy: "status", grouping: true, elbow: true).1.statusElbow)
        #expect(!sections(groupBy: "status", grouping: true).1.statusElbow)
    }

    @Test func groupProjectsByOffersStatus() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: SidebarSectionsSetting.groupByPath))
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("sidebar.groupBy is not a choice: \(descriptor.kind)")
            return
        }
        #expect(choices.map(\.value) == ["none", "folder", "status"])
        #expect(descriptor.defaultValue == .string("none"))
    }
}
