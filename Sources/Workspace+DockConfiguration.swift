import CmuxCore
import Foundation

extension Workspace {
    func windowDockConfigurationContext() -> DockConfigurationContext {
        dockConfigurationContext(includesGlobalFallback: true)
    }

    func workspaceDockConfigurationContext() -> DockConfigurationContext {
        dockConfigurationContext(includesGlobalFallback: false)
    }

    private func dockConfigurationContext(
        includesGlobalFallback: Bool
    ) -> DockConfigurationContext {
        let home = DockConfigPath(FileManager.default.homeDirectoryForCurrentUser.path)!
        if usesRemoteDirectoryProvenance, let configuration = remoteConfiguration {
            let root = trustedRemoteCurrentDirectory.flatMap(DockConfigPath.init)
            let origin = DockConfigOrigin.remote(
                identity: Self.remoteDockTrustIdentity(configuration),
                displayTarget: configuration.displayTarget
            )
            let projectSource = root.map {
                DockProjectConfigSource(
                    origin: origin,
                    fileSystem: RemoteDockConfigFileSystem(controller: remoteSessionController),
                    rootDirectory: $0,
                    boundaryDirectory: DockConfigPath("/")!,
                    executionContext: .remote(DockRemoteExecutionContext(
                        workspaceID: id,
                        foregroundAuth: SSHPTYAttachStartupCommandBuilder.foregroundAuth(
                            for: configuration
                        )
                    ))
                )
            }
            return DockConfigurationContext(
                identity: DockConfigurationContext.Identity(
                    projectOrigin: projectSource?.origin,
                    rootDirectory: root?.value,
                    availabilityRevision: remoteDockAvailabilityRevision,
                    executionWorkspaceID: id,
                    includesGlobalFallback: includesGlobalFallback
                ),
                projectSource: projectSource,
                includesGlobalFallback: includesGlobalFallback,
                emptyBaseDirectory: root?.value ?? home.value
            )
        }

        let root = DockConfigPath(currentDirectory)
        let projectSource = root.map {
            DockProjectConfigSource(
                origin: .local,
                fileSystem: LocalDockConfigFileSystem(),
                rootDirectory: $0,
                boundaryDirectory: home,
                executionContext: .local
            )
        }
        return DockConfigurationContext(
            identity: DockConfigurationContext.Identity(
                projectOrigin: projectSource?.origin,
                rootDirectory: root?.value,
                availabilityRevision: "local",
                executionWorkspaceID: nil,
                includesGlobalFallback: includesGlobalFallback
            ),
            projectSource: projectSource,
            includesGlobalFallback: includesGlobalFallback,
            emptyBaseDirectory: root?.value ?? home.value
        )
    }

    func windowDockRemoteBrowserSettings() -> DockRemoteBrowserSettings {
        DockRemoteBrowserSettings(
            proxyEndpoint: remoteProxyEndpoint,
            bypassRemoteProxy: false,
            isRemoteWorkspace: isRemoteWorkspace,
            remoteWebsiteDataStoreIdentifier: isRemoteWorkspace ? id : nil,
            remoteStatus: browserRemoteWorkspaceStatusSnapshot()
        )
    }

    func windowDockWorkspaceSnapshot() -> WindowDockWorkspaceSnapshot {
        let browserSettings = windowDockRemoteBrowserSettings()
        return WindowDockWorkspaceSnapshot(
            configurationIdentity: windowDockConfigurationContext().identity,
            proxyEndpoint: browserSettings.proxyEndpoint,
            remoteStatus: browserSettings.remoteStatus
        )
    }

    private var remoteDockAvailabilityRevision: String {
        let capabilities = remoteDaemonStatus.capabilities.sorted().joined(separator: ",")
        return [
            remoteDaemonStatus.state.rawValue,
            remoteDaemonStatus.version ?? "",
            capabilities,
            remoteSessionController == nil ? "controller-missing" : "controller-ready",
        ].joined(separator: "|")
    }

    static func remoteDockTrustIdentity(
        _ configuration: WorkspaceRemoteConfiguration
    ) -> String {
        configuration.proxyBrokerTransportKey
    }
}
