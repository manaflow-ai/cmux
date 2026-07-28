import Combine
import Foundation

@MainActor
final class SelectedWorkspaceDirectoryObserver: ObservableObject {
    private struct Snapshot: Equatable {
        let workspaceId: UUID?
        let currentDirectory: String?
        let remoteConfiguration: WorkspaceRemoteConfiguration?
        let remoteConnectionState: WorkspaceRemoteConnectionState?
        let remoteConnectionDetail: String?
        let remoteDaemonStatus: WorkspaceRemoteDaemonStatus?
        let activeRemoteTerminalSessionCount: Int
    }

    @Published private(set) var directoryChangeGeneration: UInt64 = 0
    private weak var tabManager: TabManager?
    private var cancellable: AnyCancellable?

    func wire(tabManager: TabManager) {
        guard self.tabManager !== tabManager || cancellable == nil else { return }
        self.tabManager = tabManager
        cancellable = tabManager.selectedTabIdPublisher
            .map { [weak tabManager] tabId -> Workspace? in
                guard let tabId, let tabManager else { return nil }
                return tabManager.tabs.first(where: { $0.id == tabId })
            }
            .removeDuplicates(by: { $0?.id == $1?.id })
            .map { workspace -> AnyPublisher<(Snapshot, UInt64), Never> in
                guard let workspace else {
                    return Just(
                        Snapshot(
                            workspaceId: nil,
                            currentDirectory: nil,
                            remoteConfiguration: nil,
                            remoteConnectionState: nil,
                            remoteConnectionDetail: nil,
                            remoteDaemonStatus: nil,
                            activeRemoteTerminalSessionCount: 0
                        )
                    )
                    .map { ($0, UInt64(0)) }
                    .eraseToAnyPublisher()
                }
                let directoryChangeRevision = workspace.currentDirectoryChangeRevisionPublisher()
                return workspace.$currentDirectory
                    .combineLatest(
                        workspace.$remoteConfiguration,
                        workspace.$remoteConnectionState,
                        workspace.$remoteConnectionDetail
                    )
                    .combineLatest(
                        workspace.$remoteDaemonStatus,
                        workspace.$activeRemoteTerminalSessionCount
                    )
                    .map { values in
                        let (
                            previousValues,
                            remoteDaemonStatus,
                            activeRemoteTerminalSessionCount
                        ) = values
                        let (
                            currentDirectory,
                            remoteConfiguration,
                            remoteConnectionState,
                            remoteConnectionDetail
                        ) = previousValues
                        return Snapshot(
                            workspaceId: workspace.id,
                            currentDirectory: workspace.isRemoteWorkspace
                                ? workspace.presentedCurrentDirectory
                                : currentDirectory,
                            remoteConfiguration: remoteConfiguration,
                            remoteConnectionState: remoteConnectionState,
                            remoteConnectionDetail: remoteConnectionDetail,
                            remoteDaemonStatus: remoteDaemonStatus,
                            activeRemoteTerminalSessionCount: activeRemoteTerminalSessionCount
                        )
                    }
                    .combineLatest(directoryChangeRevision)
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates { lhs, rhs in lhs.0 == rhs.0 && lhs.1 == rhs.1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.directoryChangeGeneration &+= 1
            }
    }
}
