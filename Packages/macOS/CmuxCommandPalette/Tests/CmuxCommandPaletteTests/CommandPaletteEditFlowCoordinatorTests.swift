import CoreGraphics
import Foundation
import Testing

@testable import CmuxCommandPalette

@MainActor
@Suite("CommandPaletteEditFlowCoordinator")
struct CommandPaletteEditFlowCoordinatorTests {
    /// Recording fake host that lets each test seed the lookups and observe the
    /// side effects the coordinator drives through the seam.
    final class FakeHost: CommandPaletteEditFlowHost {
        var isPresented = false
        var shouldFocusWorkspaceDescriptionEditor = false
        var defaultWorkspaceDescriptionHeight: CGFloat = 42
        var selectedWorkspaceTarget: CommandPaletteRenameTarget?
        var focusedTabTarget: CommandPaletteRenameTarget?
        var selectedWorkspaceDescriptionTarget: CommandPaletteWorkspaceDescriptionTarget?
        var tabTitleSucceeds = true

        private(set) var beepCount = 0
        private(set) var presentCount = 0
        private(set) var dismissCount = 0
        private(set) var resetRenameFocusCount = 0
        private(set) var resetWorkspaceDescriptionFocusCount = 0
        private(set) var syncDebugCount = 0
        private(set) var shouldFocusDescriptionEditorWrites: [Bool] = []
        private(set) var workspaceTitleWrites: [(UUID, String?)] = []
        private(set) var tabTitleWrites: [(UUID, UUID, String?)] = []
        private(set) var debugLogMessages: [String] = []

        var commandPaletteEditFlowIsPresented: Bool { isPresented }

        var commandPaletteEditFlowDefaultWorkspaceDescriptionHeight: CGFloat {
            defaultWorkspaceDescriptionHeight
        }

        func commandPaletteEditFlowSelectedWorkspaceRenameTarget() -> CommandPaletteRenameTarget? {
            selectedWorkspaceTarget
        }

        func commandPaletteEditFlowFocusedTabRenameTarget() -> CommandPaletteRenameTarget? {
            focusedTabTarget
        }

        func commandPaletteEditFlowSelectedWorkspaceDescriptionTarget() -> CommandPaletteWorkspaceDescriptionTarget? {
            selectedWorkspaceDescriptionTarget
        }

        func commandPaletteEditFlowBeep() { beepCount += 1 }

        func commandPaletteEditFlowSetShouldFocusWorkspaceDescriptionEditor(_ shouldFocus: Bool) {
            shouldFocusDescriptionEditorWrites.append(shouldFocus)
            shouldFocusWorkspaceDescriptionEditor = shouldFocus
        }

        func commandPaletteEditFlowResetRenameFocus() { resetRenameFocusCount += 1 }
        func commandPaletteEditFlowResetWorkspaceDescriptionFocus() { resetWorkspaceDescriptionFocusCount += 1 }
        func commandPaletteEditFlowSyncDebugState() { syncDebugCount += 1 }
        func commandPaletteEditFlowPresent() { presentCount += 1; isPresented = true }
        func commandPaletteEditFlowDismiss() { dismissCount += 1 }

        func commandPaletteEditFlowSetWorkspaceTitle(workspaceId: UUID, title: String?) {
            workspaceTitleWrites.append((workspaceId, title))
        }

        func commandPaletteEditFlowSetTabTitle(workspaceId: UUID, panelId: UUID, title: String?) -> Bool {
            tabTitleWrites.append((workspaceId, panelId, title))
            return tabTitleSucceeds
        }

        func commandPaletteEditFlowDebugLog(_ message: @autoclosure () -> String) {
            debugLogMessages.append(message())
        }
    }

    private func presentation() -> CommandPalettePresentationModel {
        CommandPalettePresentationModel(
            defaultWorkspaceDescriptionHeight: 0,
            defaults: UserDefaults(suiteName: "edit-flow-\(UUID().uuidString)")!
        )
    }

    @Test("begin workspace rename seeds the editor and enters rename mode")
    func beginWorkspaceRename() {
        let host = FakeHost()
        let workspaceId = UUID()
        host.selectedWorkspaceTarget = CommandPaletteRenameTarget(
            kind: .workspace(workspaceId: workspaceId),
            currentName: "Old Name"
        )
        let model = presentation()
        let coordinator = CommandPaletteEditFlowCoordinator()

        coordinator.beginRenameWorkspace(host: host, presentation: model)

        #expect(model.renameDraft == "Old Name")
        #expect(host.shouldFocusDescriptionEditorWrites == [false])
        #expect(host.resetRenameFocusCount == 1)
        #expect(host.syncDebugCount == 1)
        #expect(host.beepCount == 0)
        guard case .renameInput(let target) = model.mode,
              case .workspace(let id) = target.kind else {
            Issue.record("expected renameInput(.workspace)")
            return
        }
        #expect(id == workspaceId)
    }

    @Test("begin rename with no target beeps and does not change mode")
    func beginRenameNoTarget() {
        let host = FakeHost()
        let model = presentation()
        let coordinator = CommandPaletteEditFlowCoordinator()

        coordinator.beginRenameWorkspace(host: host, presentation: model)

        #expect(host.beepCount == 1)
        if case .commands = model.mode {} else { Issue.record("mode should stay commands") }
        #expect(host.resetRenameFocusCount == 0)
    }

    @Test("open rename presents the palette when not presented")
    func openRenamePresents() {
        let host = FakeHost()
        host.focusedTabTarget = CommandPaletteRenameTarget(
            kind: .tab(workspaceId: UUID(), panelId: UUID()),
            currentName: "Tab"
        )
        let model = presentation()
        let coordinator = CommandPaletteEditFlowCoordinator()

        coordinator.openRenameTabInput(host: host, presentation: model)

        #expect(host.presentCount == 1)
    }

    @Test("apply workspace rename trims and clears empty names")
    func applyWorkspaceRenameTrims() {
        let host = FakeHost()
        let workspaceId = UUID()
        let model = presentation()
        let coordinator = CommandPaletteEditFlowCoordinator()
        let target = CommandPaletteRenameTarget(kind: .workspace(workspaceId: workspaceId), currentName: "x")

        coordinator.applyRename(target: target, proposedName: "  Renamed  ", host: host, presentation: model)
        coordinator.applyRename(target: target, proposedName: "   ", host: host, presentation: model)

        #expect(host.workspaceTitleWrites.count == 2)
        #expect(host.workspaceTitleWrites[0].1 == "Renamed")
        #expect(host.workspaceTitleWrites[1].1 == nil)
        #expect(host.dismissCount == 2)
    }

    @Test("apply tab rename beeps and aborts when the workspace is gone")
    func applyTabRenameMissingWorkspace() {
        let host = FakeHost()
        host.tabTitleSucceeds = false
        let model = presentation()
        let coordinator = CommandPaletteEditFlowCoordinator()
        let target = CommandPaletteRenameTarget(
            kind: .tab(workspaceId: UUID(), panelId: UUID()),
            currentName: "Tab"
        )

        coordinator.applyRename(target: target, proposedName: "New", host: host, presentation: model)

        #expect(host.beepCount == 1)
        #expect(host.dismissCount == 0)
    }

    @Test("continue rename only applies when mode still matches the target")
    func continueRenameGuards() {
        let host = FakeHost()
        let model = presentation()
        let coordinator = CommandPaletteEditFlowCoordinator()
        let target = CommandPaletteRenameTarget(kind: .workspace(workspaceId: UUID()), currentName: "x")

        // Mode is .commands, not .renameInput(target): no-op.
        coordinator.continueRename(target: target, host: host, presentation: model)
        #expect(host.workspaceTitleWrites.isEmpty)

        model.mode = .renameInput(target)
        model.renameDraft = "Final"
        coordinator.continueRename(target: target, host: host, presentation: model)
        #expect(host.workspaceTitleWrites.count == 1)
        #expect(host.workspaceTitleWrites[0].1 == "Final")
    }

    @Test("begin workspace description seeds the editor and enters description mode")
    func beginWorkspaceDescription() {
        let host = FakeHost()
        let workspaceId = UUID()
        host.defaultWorkspaceDescriptionHeight = 73
        host.selectedWorkspaceDescriptionTarget = CommandPaletteWorkspaceDescriptionTarget(
            workspaceId: workspaceId,
            currentDescription: "Current desc"
        )
        let model = presentation()
        // Seed a non-nil pending selection behavior so the coordinator's clear is observable.
        model.pendingTextSelectionBehavior = .selectAll
        let coordinator = CommandPaletteEditFlowCoordinator()

        coordinator.beginWorkspaceDescription(host: host, presentation: model)

        #expect(model.workspaceDescriptionDraft == "Current desc")
        #expect(model.workspaceDescriptionHeight == 73)
        #expect(model.pendingTextSelectionBehavior == nil)
        #expect(host.resetWorkspaceDescriptionFocusCount == 1)
        #expect(host.syncDebugCount == 1)
        #expect(host.beepCount == 0)
        guard case .workspaceDescriptionInput(let target) = model.mode else {
            Issue.record("expected workspaceDescriptionInput")
            return
        }
        #expect(target.workspaceId == workspaceId)
    }

    @Test("begin workspace description with no workspace beeps and stays in commands")
    func beginWorkspaceDescriptionNoTarget() {
        let host = FakeHost()
        let model = presentation()
        let coordinator = CommandPaletteEditFlowCoordinator()

        coordinator.beginWorkspaceDescription(host: host, presentation: model)

        #expect(host.beepCount == 1)
        if case .commands = model.mode {} else { Issue.record("mode should stay commands") }
        #expect(host.resetWorkspaceDescriptionFocusCount == 0)
        #expect(host.syncDebugCount == 0)
    }

    @Test("open workspace description presents the palette and seeds the editor")
    func openWorkspaceDescriptionPresentsAndSeeds() {
        let host = FakeHost()
        let workspaceId = UUID()
        host.selectedWorkspaceDescriptionTarget = CommandPaletteWorkspaceDescriptionTarget(
            workspaceId: workspaceId,
            currentDescription: "Desc"
        )
        let model = presentation()
        let coordinator = CommandPaletteEditFlowCoordinator()

        coordinator.openWorkspaceDescriptionInput(host: host, presentation: model)

        #expect(host.presentCount == 1)
        #expect(model.workspaceDescriptionDraft == "Desc")
        guard case .workspaceDescriptionInput(let target) = model.mode else {
            Issue.record("expected workspaceDescriptionInput")
            return
        }
        #expect(target.workspaceId == workspaceId)
        // The open-flow bracketing logs stay app-side; the coordinator emits only
        // the seed flow's start + armed log lines.
        #expect(host.debugLogMessages.count == 2)
        #expect(host.debugLogMessages.first?.hasPrefix("palette.wsDescription.flow.start") == true)
        #expect(host.debugLogMessages.last?.hasPrefix("palette.wsDescription.flow.armed") == true)
    }
}
