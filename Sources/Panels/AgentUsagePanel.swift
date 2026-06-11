import AppKit
import Combine
import Foundation

/// Loads agent usage snapshots off the main actor and publishes the result.
@MainActor
final class AgentUsageStore: ObservableObject {
    @Published private(set) var snapshot: AgentUsageSnapshot?
    @Published private(set) var isLoading = false

    private let scanner: AgentUsageScanner

    init(scanner: AgentUsageScanner = AgentUsageScanner()) {
        self.scanner = scanner
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let scanner = self.scanner
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = scanner.scan()
            guard let self else { return }
            await self.apply(snapshot)
        }
    }

    private func apply(_ snapshot: AgentUsageSnapshot) {
        self.snapshot = snapshot
        isLoading = false
    }
}

/// Panel that shows local Claude Code / Codex token usage and estimated cost.
@MainActor
final class AgentUsagePanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .agentUsage
    let usageStore: AgentUsageStore

    @Published private(set) var focusFlashToken: Int = 0

    init() {
        self.id = UUID()
        self.usageStore = AgentUsageStore()
    }

    var displayTitle: String {
        String(localized: "panel.agentUsage.title", defaultValue: "Agent Usage")
    }

    var displayIcon: String? { "chart.bar.xaxis" }

    func close() {}

    func focus() {}

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }
}
