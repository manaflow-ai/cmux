import Combine
import Foundation
import Observation

/// Narrows workspace observation to state that can affect the window Dock.
@MainActor
@Observable
final class WindowDockWorkspaceObservation {
    private(set) var snapshot: WindowDockWorkspaceSnapshot
    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    init(workspace: Workspace) {
        snapshot = workspace.windowDockWorkspaceSnapshot()
        observe(workspace)
    }

    func observe(_ workspace: Workspace) {
        guard self.workspace !== workspace else { return }
        self.workspace = workspace
        cancellables.removeAll()
        apply(workspace.windowDockWorkspaceSnapshot())

        let changes: [AnyPublisher<Void, Never>] = [
            workspace.$currentDirectory
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher(),
            workspace.currentDirectoryChangeRevisionPublisher()
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher(),
            workspace.$remoteConfiguration
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher(),
            workspace.$remoteDaemonStatus
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher(),
            workspace.$remoteProxyEndpoint
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher(),
            workspace.$remoteConnectionState
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher(),
            workspace.$remoteHeartbeatCount
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher(),
            workspace.$remoteLastHeartbeatAt
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher(),
        ]

        Publishers.MergeMany(changes)
            // Workspace's legacy @Published properties emit in willSet. Deliver
            // on the main queue so the immutable snapshot reads committed state.
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak workspace] in
                guard let self, let workspace, self.workspace === workspace else { return }
                self.apply(workspace.windowDockWorkspaceSnapshot())
            }
            .store(in: &cancellables)
    }

    private func apply(_ next: WindowDockWorkspaceSnapshot) {
        guard snapshot != next else { return }
        snapshot = next
    }
}
