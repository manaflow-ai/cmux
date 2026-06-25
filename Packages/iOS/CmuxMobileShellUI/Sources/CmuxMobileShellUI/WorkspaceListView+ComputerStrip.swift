#if os(iOS)
import CmuxMobileShell
import SwiftUI

struct WorkspaceComputerStripSection: View {
    let computers: [MacComputerSnapshot]
    let selectedMachineIDs: Set<String>
    let selectComputer: (MacComputerSnapshot) -> Void
    let createWorkspace: (MacComputerSnapshot) -> Void
    var showAddDevice: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if !computers.isEmpty {
            Section {
                WorkspaceComputerStripView(
                    computers: computers,
                    selectedMachineIDs: selectedMachineIDs,
                    selectComputer: selectComputer,
                    createWorkspace: createWorkspace,
                    showAddDevice: showAddDevice
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
        }
    }
}

extension WorkspaceListView {
    var canCreateWorkspace: Bool {
        connectionStatus == .connected
    }

    func selectComputerInStrip(_ computer: MacComputerSnapshot) {
        var selected = Set(computer.aliasIDs)
        selected.insert(computer.deviceId)
        filter.machines = filter.machines == selected ? [] : selected
    }

    func createWorkspaceOnComputer(_ computer: MacComputerSnapshot) {
        guard let store else { return }
        let deviceId = computer.deviceId
        let computerName = computer.title
        guard computer.connectionStatus == .connected else {
            computerWorkspaceCreationFailureID = deviceId
            computerWorkspaceCreationFailureName = computerName
            return
        }
        Task {
            let created = await store.createWorkspace(onMacDeviceID: deviceId)
            guard !created else { return }
            computerWorkspaceCreationFailureID = deviceId
            computerWorkspaceCreationFailureName = computerName
        }
    }

    func retryComputerWorkspaceCreation() {
        guard let deviceId = computerWorkspaceCreationFailureID else { return }
        let computer = store?.stableComputerSnapshots.first { $0.deviceId == deviceId }
        clearComputerWorkspaceCreationFailure()
        if let computer {
            createWorkspaceOnComputer(computer)
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
