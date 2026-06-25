#if os(iOS)
import SwiftUI

extension WorkspaceListView {
    var canCreateWorkspace: Bool {
        connectionStatus == .connected
    }

    func selectComputerInStrip(_ deviceId: String) {
        let selected = Set([deviceId])
        filter.machines = filter.machines == selected ? [] : selected
    }

    func createWorkspaceOnComputer(_ deviceId: String) {
        guard let store else { return }
        let computerName = store.stableComputerSnapshots.first { $0.deviceId == deviceId }?.title ?? deviceId
        Task {
            let created = await store.createWorkspace(onMacDeviceID: deviceId)
            guard !created else { return }
            computerWorkspaceCreationFailureID = deviceId
            computerWorkspaceCreationFailureName = computerName
        }
    }

    var computerWorkspaceCreationFailurePresented: Binding<Bool> {
        Binding(
            get: { computerWorkspaceCreationFailureID != nil },
            set: { isPresented in
                if !isPresented {
                    clearComputerWorkspaceCreationFailure()
                }
            }
        )
    }

    func clearComputerWorkspaceCreationFailure() {
        computerWorkspaceCreationFailureID = nil
        computerWorkspaceCreationFailureName = ""
    }
}
#endif
