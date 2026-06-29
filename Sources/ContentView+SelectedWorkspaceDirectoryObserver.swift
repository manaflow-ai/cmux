import Combine
import Foundation
import Observation

extension ContentView {
    @MainActor
    @Observable
    final class SelectedWorkspaceDirectoryObserver {
        private struct Snapshot: Equatable {
            let workspaceId: UUID?
            let currentDirectory: String?
            let remoteConfiguration: WorkspaceRemoteConfiguration?
            let remoteConnectionState: WorkspaceRemoteConnectionState?
            let remoteConnectionDetail: String?
            let remoteDaemonStatus: WorkspaceRemoteDaemonStatus?
            let activeRemoteTerminalSessionCount: Int?
        }

        private(set) var directoryChangeGeneration: UInt64 = 0
        @ObservationIgnored private weak var tabManager: TabManager?
        @ObservationIgnored private var cancellable: AnyCancellable?

        func wire(tabManager: TabManager) {
            guard self.tabManager !== tabManager || cancellable == nil else { return }
            self.tabManager = tabManager
            cancellable = tabManager.selectedTabIdPublisher
                .map { [weak tabManager] tabId -> Workspace? in
                    guard let tabId, let tabManager else { return nil }
                    return tabManager.tabs.first(where: { $0.id == tabId })
                }
                .removeDuplicates(by: { $0?.id == $1?.id })
                .map { workspace -> AnyPublisher<Snapshot, Never> in
                    guard let workspace else {
                        return Just(
                            Snapshot(
                                workspaceId: nil,
                                currentDirectory: nil,
                                remoteConfiguration: nil,
                                remoteConnectionState: nil,
                                remoteConnectionDetail: nil,
                                remoteDaemonStatus: nil,
                                activeRemoteTerminalSessionCount: nil
                            )
                        )
                        .eraseToAnyPublisher()
                    }
                    return workspace.$currentDirectory
                        .combineLatest(
                            workspace.$remoteConfiguration,
                            workspace.$remoteConnectionState,
                            workspace.$remoteConnectionDetail
                        )
                        .combineLatest(workspace.$remoteDaemonStatus)
                        .combineLatest(workspace.$activeRemoteTerminalSessionCount)
                        .map { values, activeRemoteTerminalSessionCount in
                            let (values, remoteDaemonStatus) = values
                            let (
                                currentDirectory,
                                remoteConfiguration,
                                remoteConnectionState,
                                remoteConnectionDetail
                            ) = values
                            return Snapshot(
                                workspaceId: workspace.id,
                                currentDirectory: currentDirectory,
                                remoteConfiguration: remoteConfiguration,
                                remoteConnectionState: remoteConnectionState,
                                remoteConnectionDetail: remoteConnectionDetail,
                                remoteDaemonStatus: remoteDaemonStatus,
                                activeRemoteTerminalSessionCount: activeRemoteTerminalSessionCount
                            )
                        }
                        .eraseToAnyPublisher()
                }
                .switchToLatest()
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.directoryChangeGeneration &+= 1
                }
        }
    }
}
