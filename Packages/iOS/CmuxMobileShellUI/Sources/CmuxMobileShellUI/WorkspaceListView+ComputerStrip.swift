#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

struct WorkspaceComputerStripSection: View {
    let computers: [MacComputerSnapshot]
    let selectedMachineIDs: Set<String>
    let createWorkspace: (MacComputerSnapshot) -> Void
    let manageComputer: (MacComputerSnapshot) -> Void
    let removeComputer: (MacComputerSnapshot) -> Void
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
                    removeComputer: removeComputer,
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

    func requestComputerRemovalFromStrip(_ computer: MacComputerSnapshot) {
        computerPendingRemoval = computer
    }

    func confirmComputerRemovalFromStrip() {
        guard let computer = computerPendingRemoval, let store else { return }
        let deviceId = computer.deviceId
        computerPendingRemoval = nil
        Task {
            await store.forgetMac(macDeviceID: deviceId)
            await store.loadPairedMacs()
            await store.loadRegistryDevices()
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

    var computerRemovalPresented: Binding<Bool> {
        Binding(
            get: { computerPendingRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    computerPendingRemoval = nil
                }
            }
        )
    }

    func removeComputerTitle(_ computer: MacComputerSnapshot?) -> String {
        String(
            format: L10n.string("mobile.computers.removeTitleFormat", defaultValue: "Remove %@?"),
            computer?.title ?? ""
        )
    }

    func removeComputerMessage(_ computer: MacComputerSnapshot?) -> String {
        guard let computer, computer.aliasIDs.count > 1 else {
            return L10n.string(
                "mobile.computers.removeMessage",
                defaultValue: "This computer and its workspaces stop appearing here. Pair it again to add it back."
            )
        }
        return String(
            format: L10n.string(
                "mobile.computers.removeMessageRepresentativeFormat",
                defaultValue: "This removes paired record %@. Other matching records may still appear."
            ),
            computer.deviceId
        )
    }
}

extension View {
    func workspaceComputerManagementPresentation(
        store: CMUXMobileShellStore?,
        detailID: String?,
        detailPresented: Binding<Bool>,
        dismissDetail: @escaping () -> Void,
        pendingRemoval: MacComputerSnapshot?,
        removalPresented: Binding<Bool>,
        confirmRemoval: @escaping () -> Void,
        cancelRemoval: @escaping () -> Void,
        removeTitle: String,
        removeMessage: String
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
            .confirmationDialog(removeTitle, isPresented: removalPresented, titleVisibility: .visible) {
                if pendingRemoval != nil {
                    Button(L10n.string("mobile.computers.remove", defaultValue: "Remove"), role: .destructive) {
                        confirmRemoval()
                    }
                }
                Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {
                    cancelRemoval()
                }
            } message: {
                Text(removeMessage)
            }
    }
}
#endif
