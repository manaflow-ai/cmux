import Bonsplit
import Foundation
import Observation

/// Main-actor state and shared actions for the cross-workspace Herd surface.
@MainActor
@Observable
final class HerdPanelModel {
    enum Filter: String, CaseIterable, Sendable {
        case all
        case agents
        case needsInput
    }

    enum Feedback: Equatable {
        case promptSent
        case promptPastedButNotSubmitted
        case terminalUnavailable
    }

    private(set) var snapshot = HerdPanelSnapshot.empty
    private(set) var transcript = ""
    private(set) var feedback: Feedback?
    var selectedLaneID: HerdPanelSnapshot.LaneID?
    var filter: Filter = .agents
    var prompt = ""

    @ObservationIgnored
    private weak var tabManager: TabManager?

    var filteredLanes: [HerdPanelSnapshot.Lane] {
        switch filter {
        case .all:
            snapshot.lanes
        case .agents:
            snapshot.lanes.filter(\.isAgent)
        case .needsInput:
            snapshot.lanes.filter { $0.lifecycle == .needsInput }
        }
    }

    var selectedLane: HerdPanelSnapshot.Lane? {
        guard let selectedLaneID else { return nil }
        return snapshot.lanes.first { $0.id == selectedLaneID }
    }

    func attach(tabManager: TabManager) {
        guard self.tabManager !== tabManager else {
            refreshSnapshot()
            return
        }
        self.tabManager = tabManager
        refreshSnapshot()
    }

    func refreshSnapshot() {
        guard let tabManager else { return }
        snapshot = HerdPanelSnapshot.capture(tabManager: tabManager)

        if let selectedLaneID, snapshot.lanes.contains(where: { $0.id == selectedLaneID }) {
            return
        }
        selectedLaneID = snapshot.lanes.first(where: \.isAgent)?.id ?? snapshot.lanes.first?.id
        refreshTranscript()
    }

    func select(_ lane: HerdPanelSnapshot.Lane) {
        selectedLaneID = lane.id
        feedback = nil
        refreshTranscript()
    }

    func refreshTranscript() {
        guard let target = resolvedSelectedTerminal() else {
            transcript = ""
            return
        }
        transcript = TerminalController.shared.readTerminalTextForSnapshot(
            terminalPanel: target.panel,
            includeScrollback: true,
            lineLimit: 160
        ) ?? ""
    }

    func focusSelectedLane() {
        guard let tabManager, let lane = selectedLane else { return }
        tabManager.focusTab(lane.workspaceID, surfaceId: lane.panelID)
        refreshSnapshot()
    }

    func splitSelectedLane(orientation: SplitOrientation) {
        guard let lane = selectedLane,
              let workspace = tabManager?.tabs.first(where: { $0.id == lane.workspaceID }) else {
            return
        }
        _ = workspace.newTerminalSplit(from: lane.panelID, orientation: orientation, focus: true)
        refreshSnapshot()
    }

    func interruptSelectedLane(hard: Bool) {
        guard let target = resolvedSelectedTerminal() else { return }
        _ = target.panel.sendNamedKeyResult(hard ? "ctrl+c" : "escape")
        target.panel.surface.forceRefresh(reason: "herd.interrupt")
        refreshTranscript()
    }

    func sendPrompt() {
        guard let target = resolvedSelectedTerminal() else {
            feedback = .terminalUnavailable
            return
        }
        guard let submitted = TextBoxSubmit.submittedPasteText(for: prompt) else { return }

        let context = WorkspaceContentView.terminalAgentContext(
            panel: target.panel,
            workspace: target.workspace
        )
        let submitKey = TextBoxAgentDetection.composedPromptSubmitKey(
            containsNewline: submitted.contains("\n") || submitted.contains("\r"),
            context: context
        )
        guard target.panel.sendText(submitted) else {
            feedback = .terminalUnavailable
            return
        }

        let submitResult = target.panel.sendNamedKeyResult(submitKey)
        target.panel.surface.forceRefresh(reason: "herd.prompt")
        if submitResult.accepted {
            _ = tabManager?.handlePromptSubmit(workspaceId: target.workspace.id, message: submitted)
            prompt = ""
            feedback = .promptSent
        } else {
            feedback = .promptPastedButNotSubmitted
        }
        refreshTranscript()
    }

    private func resolvedSelectedTerminal() -> (workspace: Workspace, panel: TerminalPanel)? {
        guard let lane = selectedLane,
              let workspace = tabManager?.tabs.first(where: { $0.id == lane.workspaceID }),
              let panel = workspace.terminalInputTarget(forPanelID: lane.panelID)?.panel else {
            return nil
        }
        return (workspace, panel)
    }
}
