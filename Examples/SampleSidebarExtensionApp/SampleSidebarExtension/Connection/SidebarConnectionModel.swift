import Foundation
import Observation
import SwiftUI
import CmuxExtensionKit

@Observable
@MainActor
final class SidebarConnectionModel {
    private(set) var snapshot: CMUXSidebarSnapshot?
    private(set) var errorText: String?

    @ObservationIgnored
    private var host: CmuxSidebarHost?

    @ObservationIgnored
    private var cmux: CmuxHost?

    func update(context: CmuxSidebarContext) {
        snapshot = context.snapshot
        host = context.host
        cmux = context.cmux
        errorText = nil
    }

    func connectionErrorDidChange(_ message: String?) {
        errorText = message.map(Self.localizedHostMessage)
    }

    var insights: SidebarInsightModel? {
        snapshot.map(SidebarInsightModel.init(snapshot:))
    }

    func refreshSnapshot() {
        host?.refresh()
    }

    func selectWorkspace(_ id: UUID) {
        guard let host else { return }
        Task { @MainActor in
            let result = await host.selectWorkspace(id)
            if result.accepted {
                errorText = nil
            } else {
                errorText = result.message ?? String(localized: "sampleSidebar.actionDenied", defaultValue: "cmux did not allow that action")
            }
        }
    }

    func selectSurface(workspaceID: UUID, surfaceID: UUID) {
        guard let host else { return }
        Task { @MainActor in
            let result = await host.selectSurface(workspaceID: workspaceID, surfaceID: surfaceID)
            apply(result)
        }
    }

    func selectPreviousWorkspace() {
        guard let cmux else { return }
        Task { @MainActor in
            apply(await cmux.selectPreviousWorkspace())
        }
    }

    func selectNextWorkspace() {
        guard let cmux else { return }
        Task { @MainActor in
            apply(await cmux.selectNextWorkspace())
        }
    }

    func selectPreviousSurface() {
        guard let host else { return }
        Task { @MainActor in
            apply(await host.selectPreviousSurface())
        }
    }

    func selectNextSurface() {
        guard let host else { return }
        Task { @MainActor in
            apply(await host.selectNextSurface())
        }
    }

    func createTerminalSurface(in workspaceID: UUID?) {
        guard let host else { return }
        Task { @MainActor in
            apply(await host.createTerminalSurface(in: workspaceID))
        }
    }

    private func apply(_ result: CMUXExtensionActionResult) {
        if result.accepted {
            errorText = nil
        } else {
            errorText = result.message ?? String(localized: "sampleSidebar.actionDenied", defaultValue: "cmux did not allow that action")
        }
    }

    private static func localizedHostMessage(_ message: String) -> String {
        switch message {
        case "Waiting for cmux":
            return String(localized: "sampleSidebar.waitingForHost", defaultValue: "Waiting for cmux")
        case "cmux did not send a workspace snapshot":
            return String(localized: "sampleSidebar.emptySnapshot", defaultValue: "cmux did not send a workspace snapshot")
        default:
            return message
        }
    }
}
