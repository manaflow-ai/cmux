import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Cold-launch coverage for Leo's first Cmd-N jump: restore several existing rows,
/// select a middle workspace, then ensure the first drawn new row stays immediately below it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ColdCmdNRowSlotTests {
    private static func rows(_ layout: SidebarLayout) -> [String] {
        layout.rows.compactMap { row in
            if case let .workspace(id) = row.key { return id.rawValue }
            return nil
        }
    }

    @Test func firstColdCmdNWithRestoredFollowingRowsStaysAfterCurrent() async throws {
        let names = (1...3).map { "cold-restore-\($0)" }
        let launched = try await RapidWorkspaceCreateTests.launch(sessionEvents: true, preseedWorkspaceNames: names)
        do {
            let services = launched.services
            let window = try #require(services.windows.active?.state.id)
            let controller = try #require(services.windows.controller(for: window))
            let state = controller.state
            let list = controller.sidebar.container.sidebarView.list
            let store = services.daemon.store
            let config = launched.root.appendingPathComponent("cmux.json")
            try Data(#"{"workspaces":{"newPlacement":"afterCurrent"}}"#.utf8).write(to: config)
            let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: config,
                                              managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
            await settings.reload()
            services.settings = settings
            try #require(services.settings?.snapshot.newWorkspacePlacement == .afterCurrent)
            await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { services.sidebarDoc.store?.shown != nil }
            try #require(services.sidebarDoc.store?.shown != nil, "the same-tree daemon serves the sidebar document")

            // These workspaces were persisted before AppServices and the first window connected; this is a true cold restore.
            await RapidWorkspaceCreateTests.wait(within: .seconds(30)) {
                names.allSatisfy { name in store.workspaces.contains { $0.name == name && !$0.isProvisional } }
            }
            let restored = try #require(names.compactMap { name in store.workspaces.first { $0.name == name && !$0.isProvisional } }.count == names.count
                ? names.compactMap { name in store.workspaces.first { $0.name == name && !$0.isProvisional } } : nil,
                "restored workspaces: \(store.workspaces.map(\.name))")
            for workspace in restored {
                services.windows.claim(workspaceID: workspace.id, in: state, select: false)
            }
            await RapidWorkspaceCreateTests.wait(within: .seconds(30)) {
                restored.allSatisfy { services.windows.registry.value.owner(of: $0.id) == window }
            }
            await RapidWorkspaceCreateTests.wait(within: .seconds(30)) {
                let drawn = Self.rows(list.displayed)
                return restored.allSatisfy { drawn.contains($0.id) }
            }

            let drawnOrder = Self.rows(list.displayed)
            let ordered = restored.sorted { (drawnOrder.firstIndex(of: $0.id) ?? Int.max) < (drawnOrder.firstIndex(of: $1.id) ?? Int.max) }
            let current = ordered[ordered.count / 2]
            services.windows.select(current.id, in: state)
            controller.showWorkspace(requested: state.workspaceID)
            await RapidWorkspaceCreateTests.wait(within: .seconds(10)) {
                state.workspaceID == current.id && Self.rows(list.displayed).contains(current.id)
            }
            let before = Self.rows(list.displayed)
            let anchor = try #require(before.firstIndex(of: current.id), "middle workspace is not drawn: \(before)")
            try #require(anchor + 1 < before.count, "need a row following the selected middle workspace: \(before)")

            // Exercise the pending stand-in directly while the restored sidebar projection is
            // empty. The real placement rule carries the current machine from the Cmd-N press;
            // the pre-fix path resolved this state to a top/bottom frame.
            let machine = try #require(services.machines.daemon(forWorkspace: current.id)?.machineID,
                                       "current workspace daemon is unavailable")
            let probeRule = NewWorkspacePlacements.rule(for: window, in: services.windows)
            let probe = PendingWorkspaceRows.Row(
                id: "cold-probe",
                window: window,
                machine: MachineID(machine),
                face: SidebarMapping.shared.creatingRow(id: "cold-probe", machine: MachineID(machine), name: "cold-probe", opensPage: true),
                slot: nil,
                byDefault: probeRule
            )
            let staleSections = [SidebarRowSection(
                kind: .machine(SidebarMachine(id: MachineID(machine), name: "This Mac", kind: .local)), nodes: [])
            ]
            // The document's drawn projection is a hop behind, as on a cold launch.
            let document = try #require(services.sidebarDoc.store)
            document.shownVersion = document.version &- 1
            let catchingUp = NewWorkspaceDefaultSlot.layoutCatchingUp(document, rowsAt: document.shownChanges)
            #expect(catchingUp)
            let coldFrame = PendingWorkspaceRows.adding([probe], to: staleSections, home: nil, catchingUp: catchingUp)
            #expect(coldFrame.flatMap(\.workspaces).isEmpty, "a stale cold layout must not draw a top or bottom frame")
            let settledSections = [SidebarRowSection(
                kind: .machine(SidebarMachine(id: MachineID(machine), name: "This Mac", kind: .local)),
                nodes: [.workspace(SidebarWorkspace(id: WorkspaceID(current.id), machineID: MachineID(machine), title: "current"))]
            )]
            let settledFrame = PendingWorkspaceRows.adding([probe], to: settledSections, home: nil, catchingUp: catchingUp)
            #expect(settledFrame.flatMap(\.workspaces).map(\.id.rawValue) == [current.id, "cold-probe"])
            #expect(!probeRule.awaitsCurrentAnchor(section: .machine(MachineID(machine)), in: staleSections, catchingUp: false),
                    "once the layout caught up, a current row left out on purpose (filter, space, close) uses the normal fallback")
            let bottomRule = NewWorkspaceDefaultSlot(placement: .bottom, current: nil)
            let bottom = PendingWorkspaceRows.Row(
                id: "bottom-probe", window: window, machine: MachineID(machine),
                face: SidebarMapping.shared.creatingRow(id: "bottom-probe", machine: MachineID(machine), name: "bottom-probe", opensPage: true),
                slot: nil, byDefault: bottomRule)
            let bottomFrame = PendingWorkspaceRows.adding([bottom], to: staleSections, home: nil, catchingUp: catchingUp)
            #expect(bottomFrame.flatMap(\.workspaces).map(\.id.rawValue) == ["bottom-probe"],
                    "bottom placement keeps its immediate loose-row stand-in")

            // An updater can leave the first cold layout one projection behind while AppKit has no
            // realized row geometry yet. Keep that state across the first Cmd-N so it cannot expose
            // the daemon's temporary tail placement as a visible bottom frame.
            document.shownVersion = document.version &- 1
            controller.sidebar.model.setSections([])
            controller.sidebar.container.sidebarView.renderNow()

            var frames: [[String]] = []
            let previousOnApply = list.onApply
            defer { list.onApply = previousOnApply }
            list.onApply = { layout in previousOnApply?(layout); frames.append(Self.rows(layout)) }
            _ = services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string("cold-target")]))
            await RapidWorkspaceCreateTests.wait(within: .seconds(30)) {
                store.workspaces.contains { $0.name == "cold-target" && !$0.isProvisional }
                    && Self.rows(list.displayed).contains { id in store.workspaces.first { $0.id == id }?.name == "cold-target" }
                    && PendingWorkspaceRows.shared.rows(in: window).isEmpty
            }
            let target = try #require(store.workspaces.first { $0.name == "cold-target" }?.id, "new workspace never entered the store")
            // Settled: the daemon confirmed the new row's document item and the list draws the projection of the
            // document's current version, so no later reconciliation is still on its way to the list.
            let docMachines = services.sidebarDoc.docMachines
            await RapidWorkspaceCreateTests.wait(within: .seconds(30)) {
                guard let doc = services.sidebarDoc.store, docMachines.item(workspace: target) != nil else { return false }
                return doc.shownVersion == doc.version && Self.rows(list.displayed).contains(target)
            }
            try #require(docMachines.item(workspace: target) != nil, "the daemon never confirmed the new row's document item")
            let targetFrames = frames.filter { $0.contains(target) }
            let expected = anchor + 1
            let misplaced = targetFrames.filter { frame in
                frame.firstIndex(of: target) != frame.firstIndex(of: current.id).map { $0 + 1 }
            }
            let final = Self.rows(list.displayed)

            #expect(!targetFrames.isEmpty, "no drawn frame contained the new workspace: \(frames)")
            #expect(misplaced.isEmpty, "cold Cmd-N row moved from after-current \(expected): \(misplaced)")
            #expect(final.firstIndex(of: target) == final.firstIndex(of: current.id).map { $0 + 1 }, "final rows: \(final)")
        } catch {
            await launched.stop()
            throw error
        }
        await launched.stop()
    }
}
