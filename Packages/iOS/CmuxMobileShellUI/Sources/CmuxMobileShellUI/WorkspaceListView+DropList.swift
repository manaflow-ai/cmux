import CmuxMobileSupport
import SwiftUI

extension WorkspaceListView {
    var workspaceDropList: some View {
        List {
            switch connectionChrome {
            case .recoveryBanner:
                if let store {
                    Section {
                        MobileConnectionRecoveryBanner(
                            connectionRequiresReauth: store.connectionRequiresReauth,
                            connectionRecoveryFailed: store.connectionRecoveryFailed,
                            isRecoveringConnection: store.isRecoveringConnection,
                            connectionError: store.connectionError,
                            retry: { store.retryMobileConnection() },
                            signOut: signOut,
                            rendersInline: true
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowSeparator(.hidden)
                    }
                }
            case .macStatusRow:
                Section {
                    MobileMacConnectionStatusRow(
                        host: host,
                        status: connectionStatus,
                        showsSpinner: isInitialConnectionLoading,
                        titleOverride: initialConnectionTimedOut
                            ? L10n.string("mobile.loading.timeout.title", defaultValue: "Still loading")
                            : nil,
                        descriptionOverride: initialConnectionTimedOut
                            ? L10n.string(
                                "mobile.loading.timeout.message",
                                defaultValue: "cmux could not finish restoring this session. Check that the selected cmux build is running, then retry or add this computer again."
                            )
                            : nil,
                        retry: initialConnectionTimedOut ? retryInitialConnection : nil,
                        addDevice: initialConnectionTimedOut ? showAddDevice : nil,
                        reconnect: reconnect
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowSeparator(.hidden)
                }
            case .none:
                EmptyView()
            }
            Section {
                if rendersGroupedSections {
                    groupedRows
                } else if activeFilter.isActive,
                          trimmedQuery.isEmpty,
                          filteredWorkspaces.isEmpty,
                          !workspaces.isEmpty {
                    WorkspaceListFilterEmptyRow(filter: activeFilter) {
                        filter = .all
                        macSelection = .all
                    }
                    .listRowSeparator(.hidden)
                } else {
                    flatRows
                }
            }
        }
    }
}
