#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

struct WorkspaceComputerStripSection: View {
    let computers: [MacComputerSnapshot]
    let selectedMachineIDs: Set<String>
    let createWorkspace: (MacComputerSnapshot) -> Void
    let manageComputer: (MacComputerSnapshot) -> Void
    let canCreateFallbackWorkspace: Bool
    let createFallbackWorkspace: () -> Void
    var showAddDevice: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if !computers.isEmpty {
            Section {
                WorkspaceComputerStripView(
                    computers: computers,
                    selectedMachineIDs: selectedMachineIDs,
                    createWorkspace: createWorkspace,
                    manageComputer: manageComputer,
                    showAddDevice: showAddDevice
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
        } else if canCreateFallbackWorkspace {
            Section {
                Button(action: createFallbackWorkspace) {
                    Label(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"), systemImage: "plus")
                }
                .accessibilityIdentifier("MobileWorkspaceComputerStripFallbackNew")
            }
        }
    }
}

extension WorkspaceListView {
    var canCreateWorkspace: Bool {
        connectionStatus == .connected
    }

    func createWorkspaceOnComputer(_ computer: MacComputerSnapshot) {
        guard let store else { return }
        let deviceId = computer.deviceId
        let computerName = computer.title
        Task {
            let created: Bool
            if let createWorkspaceOnComputerID {
                created = await createWorkspaceOnComputerID(deviceId)
            } else {
                created = await store.createWorkspace(onMacDeviceID: deviceId)
            }
            guard !created else { return }
            computerWorkspaceCreationFailureID = deviceId
            computerWorkspaceCreationFailureName = computerName
        }
    }

    func manageComputerFromStrip(_ computer: MacComputerSnapshot) {
        computerPendingDetailID = computer.deviceId
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

    var computerDetailPresented: Binding<Bool> {
        Binding(
            get: { computerPendingDetailID != nil },
            set: { isPresented in
                if !isPresented {
                    computerPendingDetailID = nil
                }
            }
        )
    }

}

extension View {
    func workspaceComputerManagementPresentation(
        store: CMUXMobileShellStore?,
        detailID: String?,
        detailPresented: Binding<Bool>,
        dismissDetail: @escaping () -> Void
    ) -> some View {
        self
            .sheet(isPresented: detailPresented) {
                NavigationStack {
                    if let store, let detailID {
                        MacComputerDetailView(store: store, macDeviceID: detailID)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                                        dismissDetail()
                                    }
                                }
                            }
                    }
                }
            }
    }
}
#endif
