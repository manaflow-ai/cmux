import Combine
import Foundation
import Observation

@MainActor
@Observable
final class SelectedWorkspaceDirectoryObserver {
    private(set) var directoryChangeGeneration: UInt64 = 0
    @ObservationIgnored
    private weak var tabManager: TabManager?
    @ObservationIgnored
    private var cancelObservation: (() -> Void)?

    func wire(tabManager: TabManager) {
        guard self.tabManager !== tabManager || cancelObservation == nil else { return }
        cancelObservation?()
        self.tabManager = tabManager
        let subscription = tabManager.selectedTabIdPublisher
            .map { [weak tabManager] tabId -> Workspace? in
                guard let tabId, let tabManager else { return nil }
                return tabManager.tabs.first(where: { $0.id == tabId })
            }
            .removeDuplicates(by: { $0?.id == $1?.id })
            .map { workspace -> AnyPublisher<(SelectedWorkspaceDirectorySnapshot, UInt64), Never> in
                guard let workspace else {
                    return Just(
                        SelectedWorkspaceDirectorySnapshot(
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
                        return SelectedWorkspaceDirectorySnapshot(
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
        cancelObservation = { subscription.cancel() }
    }
}
