import AppKit
import CmuxFleet
import Foundation
import SwiftUI

@MainActor
final class FleetBoardStore: ObservableObject {
    static let shared = FleetBoardStore()

    @Published private(set) var snapshot: FleetBoardSnapshot = .empty
    @Published var selectedFleetID: FleetID? {
        didSet {
            guard oldValue != selectedFleetID else { return }
            refresh()
        }
    }

    private let engine: FleetEngine
    private var refreshScheduled = false
    private var needsRefresh = false

    private init() {
        self.engine = FleetAppHost.shared.engine
        engine.onStateChange = { [weak self] in
            self?.scheduleRefresh()
        }
        refresh()
    }

    func scheduleRefresh() {
        needsRefresh = true
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            guard self.needsRefresh else { return }
            self.needsRefresh = false
            self.refresh()
        }
    }

    func openTask(_ id: FleetTaskID) {
        switch FleetTaskWorkspaceOpener.openTask(id, engine: engine) {
        case .opened:
            break
        case .workspaceUnavailable, .taskNotFound:
            NSSound.beep()
        }
    }

    func retryTask(_ id: FleetTaskID) {
        if case .ok = engine.retryTask(id: id) {
            return
        }
        NSSound.beep()
    }

    func cancelTask(_ id: FleetTaskID) {
        if case .ok = engine.cancelTask(id: id) {
            return
        }
        NSSound.beep()
    }

    func addTask(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let fleetID = snapshot.selectedFleet?.id else { return }
        if case .failure = engine.addTask(fleetID: fleetID, title: trimmed, body: nil, priority: nil) {
            NSSound.beep()
        }
    }

    func startSelectedFleet() {
        guard let fleetID = snapshot.selectedFleet?.id, engine.startFleet(id: fleetID) else {
            NSSound.beep()
            return
        }
    }

    func stopSelectedFleet() {
        guard let fleetID = snapshot.selectedFleet?.id, engine.stopFleet(id: fleetID) else {
            NSSound.beep()
            return
        }
    }

    func createFleet(
        name: String,
        repoRoot: String,
        agentCommand: String?,
        maxConcurrent: Int?
    ) -> Result<FleetConfig, FleetCreateError> {
        let result = engine.createFleet(
            name: name,
            repoRoot: repoRoot,
            agentCommandTemplate: agentCommand,
            maxConcurrent: maxConcurrent
        )
        if case .success(let config) = result {
            selectedFleetID = config.id
        }
        return result
    }

    private func refresh() {
        let configs = engine.fleetConfigs()
        if selectedFleetID == nil || !configs.contains(where: { $0.id == selectedFleetID }) {
            selectedFleetID = configs.first?.id
            return
        }
        var running: [FleetID: Bool] = [:]
        var tasks: [FleetID: [FleetTask]] = [:]
        for config in configs {
            running[config.id] = engine.isFleetRunning(id: config.id) ?? false
            tasks[config.id] = (try? engine.tasks(fleetID: config.id, state: nil).get().map(\.task)) ?? []
        }
        let next = FleetBoardProjection.makeSnapshot(
            configs: configs,
            isRunningByID: running,
            tasksByFleetID: tasks,
            selectedFleetID: selectedFleetID
        )
        if snapshot != next {
            snapshot = next
        }
    }
}
