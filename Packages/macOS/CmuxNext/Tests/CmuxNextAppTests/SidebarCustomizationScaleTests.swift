import CmuxNextCompat
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Sidebar customization (`sidebar.sections`, `sidebar.workspaces`) at the sizes a heavy user reaches, through the real
/// model: the settings apply on every projection, and the cost of a click or a projection stays per workspace, not per
/// workspace squared. Leo 2026-11-17: "we should be stress testing everything that isn't already stress tested"; "No
/// soaks: break it fast, repeatedly, under load". Each test prints its `CUSTOMIZE-SCALE` numbers.
@MainActor @Suite(.serialized) struct SidebarCustomizationScaleTests {
    static func workspace(_ id: String) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), title: "workspace \(id)")
    }

    /// `count` workspaces in one machine section: half in groups of five (`cs-g<k>`), half loose; then a `recents`
    /// section of three.
    static func sections(_ count: Int) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let grouped = count / 2
        var nodes: [SidebarNode] = stride(from: 0, to: grouped, by: 5).map { start in
            .group(SidebarGroup(id: GroupID("cs-g\(start / 5)"), name: "Group \(start / 5)",
                                workspaces: (start..<min(grouped, start + 5)).map { workspace("cs-\($0)") }))
        }
        nodes += (grouped..<count).map { .workspace(workspace("cs-\($0)")) }
        let recents = SidebarSection(kind: .custom(.init(id: "recents", title: "Recents", showsTitle: true, region: .bottom)),
                                     nodes: (0..<3).map { .workspace(workspace("r-\($0)")) })
        return [SidebarSection(kind: .machine(machine), nodes: nodes), recents]
    }

    /// A regroup rule for every loose workspace: each moves into a group of its own section.
    static func regroupEveryLoose(_ count: Int) -> SidebarProjectionCustomization {
        let groups = max(1, count / 10)
        let rules = Dictionary(uniqueKeysWithValues: (count / 2..<count).map { w in
            ("cs-\(w)", SidebarProjectionCustomization.Workspace(group: "cs-g\(w % groups)"))
        })
        return SidebarProjectionCustomization(workspaces: rules)
    }

    static func nanoseconds(_ body: () -> Void) -> UInt64 {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return DispatchTime.now().uptimeNanoseconds &- start
    }

    static func members(_ model: SidebarModel, _ group: String) -> [String] {
        for section in model.sections {
            for case let .group(found) in section.nodes where found.id.rawValue == group {
                return found.workspaces.map(\.id.rawValue)
            }
        }
        return []
    }

    @Test func regroupRulesMoveEveryRowOnceInIdOrder() {
        let base = Self.sections(20)
        let model = SidebarModel(sections: base)
        // Loose cs-10..cs-19 into groups 0 and 1; cs-0 (group 0) into group 1; cs-5 (group 1) stays.
        var rules = Self.regroupEveryLoose(20).workspaces
        rules["cs-0"] = .init(group: "cs-g1")
        model.sectionCustomization = SidebarProjectionCustomization(workspaces: rules)
        model.setSections(base)
        #expect(Self.members(model, "cs-g0") == ["cs-1", "cs-2", "cs-3", "cs-4", "cs-10", "cs-12", "cs-14", "cs-16", "cs-18"])
        #expect(Self.members(model, "cs-g1") == ["cs-5", "cs-6", "cs-7", "cs-8", "cs-9",
                                                 "cs-0", "cs-11", "cs-13", "cs-15", "cs-17", "cs-19"])
        let listed = model.sections.flatMap { $0.nodes.flatMap(\.workspaces) }.map(\.id.rawValue)
        #expect(listed.count == 23)
        #expect(Set(listed).count == 23)
    }

    /// One projection with a regroup rule for every loose workspace. Before: each move searched every section and
    /// copied the projection, so 5,000 workspaces cost about 10 times as much per workspace as 500.
    @Test func aRegroupRuleForEveryWorkspaceCostsTheSamePerWorkspace() {
        var perWorkspace: [Int: Double] = [:]
        for count in [500, 5000] {
            let base = Self.sections(count)
            let model = SidebarModel(sections: base)
            model.setSections(base)
            let customization = Self.regroupEveryLoose(count)
            var samples: [UInt64] = []
            for run in 0..<10 {
                // Alternate the settings so each set projects again (an unchanged value is skipped).
                samples.append(Self.nanoseconds { model.sectionCustomization = run.isMultiple(of: 2) ? customization : .defaults })
            }
            let projected = samples.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element).sorted()
            let median = Double(projected[projected.count / 2])
            perWorkspace[count] = median / Double(count)
            print("CUSTOMIZE-SCALE regroup workspaces=\(count) rules=\(count / 2) projection_us=\(Int(median / 1000))")
        }
        let small = perWorkspace[500] ?? 1, large = perWorkspace[5000] ?? 0
        #expect(large <= small * 4, "5,000 workspaces cost \(large) ns per workspace vs \(small) at 500")
    }

    /// A click on a workspace the settings do not hide projects nothing again: a click costs the same at 50
    /// workspaces and 5,000. Before: any hide rule made every click send the whole sidebar through the planner.
    @Test func aClickProjectsAgainOnlyWhenTheSelectionIsHidden() {
        let base = Self.sections(2000)
        let model = SidebarModel(sections: base)
        model.sectionCustomization = SidebarProjectionCustomization(hiddenSections: ["recents"],
                                                                    workspaces: ["cs-1500": .init(hidden: true)])
        model.setSections(base)
        #expect(!model.lists(WorkspaceID("cs-1500")))
        #expect(!model.lists(WorkspaceID("r-0")))

        _ = SidebarPerfCounters.report(reset: true)
        var clicks: [UInt64] = []
        for w in 1000..<1050 { clicks.append(Self.nanoseconds { model.activeWorkspaceID = WorkspaceID("cs-\(w)") }) }
        let sets = SidebarPerfCounters.report(reset: true)["section_sets", default: 0]
        clicks.sort()
        print("CUSTOMIZE-SCALE click workspaces=2000 section_sets=\(sets) click_p50_us=\(clicks[clicks.count / 2] / 1000)")
        #expect(sets == 0, "50 clicks on shown rows projected the sidebar \(sets) times")

        // The hidden row shows while it is selected, and hides again when the selection leaves it.
        model.activeWorkspaceID = WorkspaceID("cs-1500")
        #expect(model.lists(WorkspaceID("cs-1500")))
        model.activeWorkspaceID = WorkspaceID("cs-1001")
        #expect(!model.lists(WorkspaceID("cs-1500")))

        // The same for a row in a hidden section.
        model.activeWorkspaceID = WorkspaceID("r-1")
        #expect(model.lists(WorkspaceID("r-1")))
        model.activeWorkspaceID = WorkspaceID("cs-1002")
        #expect(!model.lists(WorkspaceID("r-1")))
        // A hidden row straight to another hidden row: the first hides, the second shows.
        model.activeWorkspaceID = WorkspaceID("r-2")
        model.activeWorkspaceID = WorkspaceID("cs-1500")
        #expect(!model.lists(WorkspaceID("r-2")))
        #expect(model.lists(WorkspaceID("cs-1500")))
    }
}
