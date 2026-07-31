import Foundation
import Observation
import SwiftUI
import CmuxExtensionKit

@Observable
@MainActor
final class SidebarConnectionModel {
    private(set) var snapshot: CmuxSidebarSnapshot?
    private(set) var errorText: String?

    @ObservationIgnored
    private var host: CmuxSidebarHost?
    @ObservationIgnored
    private var lifecycleMonitor: AgentLifecycleMonitor?
    private(set) var lifecycleBySurfaceID: AgentLifecycleMonitor.Statuses = [:]

    init() {
        let monitor = AgentLifecycleMonitor { [weak self] statuses in
            guard let self, lifecycleBySurfaceID != statuses else { return }
            lifecycleBySurfaceID = statuses
        }
        lifecycleMonitor = monitor
        monitor.start()
    }

    func update(context: CmuxSidebarContext) {
        snapshot = context.snapshot
        host = context.host
        errorText = nil
    }

    func connectionStatusDidChange(_ status: CmuxSidebarConnectionStatus) {
        switch status {
        case .connected:
            errorText = nil
        case .waitingForHost:
            errorText = String(localized: "surfaceSidebar.waitingForHost", defaultValue: "Waiting for cmux")
        case .error(let message):
            errorText = message
        }
    }

    func lifecycle(for surfaceID: UUID) -> SurfaceAgentLifecycle? {
        lifecycleBySurfaceID[surfaceID]
    }

    func selectWorkspace(_ id: UUID) async {
        guard let host else { return }
        await apply { try await host.selectWorkspace(id) }
    }

    func selectSurface(workspaceID: UUID, surfaceID: UUID) async {
        guard let host else { return }
        await apply { try await host.selectSurface(workspaceID: workspaceID, surfaceID: surfaceID) }
    }

    private func apply(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            errorText = nil
        } catch CmuxSidebarActionError.rejected(let message) {
            errorText = message
        } catch CmuxSidebarActionError.cancelled {
            errorText = nil
        } catch {
            errorText = String(localized: "surfaceSidebar.actionDenied", defaultValue: "cmux did not allow that action")
        }
    }

}
