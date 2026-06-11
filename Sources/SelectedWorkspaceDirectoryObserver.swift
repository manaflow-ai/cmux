import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Selected workspace directory observer
@MainActor
@Observable
final class SelectedWorkspaceDirectoryObserver {
    struct Snapshot: Equatable {
        let workspaceId: UUID?
        let currentDirectory: String?
        let remoteConfiguration: WorkspaceRemoteConfiguration?
        let remoteConnectionState: WorkspaceRemoteConnectionState?
        let remoteConnectionDetail: String?
        let remoteDaemonStatus: WorkspaceRemoteDaemonStatus?
    }

    private(set) var directoryChangeGeneration: UInt64 = 0
    @ObservationIgnored weak var tabManager: TabManager?
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
                            remoteDaemonStatus: nil
                        )
                    )
                    .eraseToAnyPublisher()
                }
                return workspace.currentDirectoryPublisher
                    .combineLatest(
                        workspace.remoteConfigurationPublisher,
                        workspace.remoteConnectionStatePublisher,
                        workspace.remoteConnectionDetailPublisher
                    )
                    .combineLatest(workspace.remoteDaemonStatusPublisher)
                    .map { values, remoteDaemonStatus in
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
                            remoteDaemonStatus: remoteDaemonStatus
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

