import CmuxTerminal
import CmuxTerminalBackend
import Foundation

/// Process-scoped terminal client dependencies shared by every window,
/// workspace, and Dock in one cmux process.
@MainActor
final class TerminalClientComposition {
    let terminalPanelFactory: any TerminalPanelCreating
    let terminalBackendClient: (any TerminalBackendClient)?
    let terminalPresentationRegistry: TerminalBackendPresentationRegistry?
    let terminalBackendTopologyAuthorizationGate: TerminalBackendTopologyAuthorizationGate?
    let terminalBackendTopologyMutationCoordinator: TerminalBackendTopologyMutationCoordinator?
    let terminalBackendTopologyAdoptionRegistry: TerminalBackendTopologyAdoptionRegistry?
    let nativeBrowserPresentationRegistry: TerminalBackendNativeBrowserPresentationRegistry
    let nativeBrowserRuntimeCoordinator: TerminalBackendNativeBrowserRuntimeCoordinator?
    let remoteTmuxSurfaceRegistry: TerminalBackendRemoteTmuxSurfaceRegistry?
    let browserEndpointFactory: any TerminalBackendBrowserEndpointCreating
    let mobileTerminalDataPlane: any MobileTerminalDataPlane
    /// Whether Swift can present a canonical browser endpoint. Production
    /// supports frontend-native WebKit endpoints, not daemon PNG frames.
    let canonicalBrowserProjectionAvailable: Bool

    init(
        terminalPanelFactory: any TerminalPanelCreating,
        terminalBackendClient: (any TerminalBackendClient)? = nil,
        terminalPresentationRegistry: TerminalBackendPresentationRegistry? = nil,
        terminalBackendTopologyAuthorizationGate: TerminalBackendTopologyAuthorizationGate? = nil,
        terminalBackendTopologyMutationCoordinator: TerminalBackendTopologyMutationCoordinator? = nil,
        terminalBackendTopologyAdoptionRegistry: TerminalBackendTopologyAdoptionRegistry? = nil,
        nativeBrowserPresentationRegistry: TerminalBackendNativeBrowserPresentationRegistry? = nil,
        nativeBrowserRuntimeCoordinator: TerminalBackendNativeBrowserRuntimeCoordinator? = nil,
        remoteTmuxSurfaceRegistry: TerminalBackendRemoteTmuxSurfaceRegistry? = nil,
        browserEndpointFactory: (any TerminalBackendBrowserEndpointCreating)? = nil,
        mobileTerminalDataPlane: any MobileTerminalDataPlane = EmbeddedMobileTerminalDataPlane(),
        canonicalBrowserProjectionAvailable: Bool = false
    ) {
        self.terminalPanelFactory = terminalPanelFactory
        self.terminalBackendClient = terminalBackendClient
        self.terminalPresentationRegistry = terminalPresentationRegistry
        self.terminalBackendTopologyAuthorizationGate = terminalBackendTopologyAuthorizationGate
        self.terminalBackendTopologyMutationCoordinator = terminalBackendTopologyMutationCoordinator
        self.terminalBackendTopologyAdoptionRegistry = terminalBackendTopologyAdoptionRegistry
        self.nativeBrowserPresentationRegistry = nativeBrowserPresentationRegistry
            ?? TerminalBackendNativeBrowserPresentationRegistry()
        self.nativeBrowserRuntimeCoordinator = nativeBrowserRuntimeCoordinator
        self.remoteTmuxSurfaceRegistry = remoteTmuxSurfaceRegistry
        self.browserEndpointFactory = browserEndpointFactory
            ?? UnsupportedTerminalBackendBrowserEndpointFactory()
        self.mobileTerminalDataPlane = mobileTerminalDataPlane
        self.canonicalBrowserProjectionAvailable = canonicalBrowserProjectionAvailable
    }

    static func embedded() -> TerminalClientComposition {
        TerminalClientComposition(
            terminalPanelFactory: EmbeddedTerminalPanelFactory(
                dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies
            )
        )
    }

    static func persistent<Client>(
        backendClient: Client,
        presentationDependencies: TerminalSurfacePresentationDependencies,
        launchDependencies: TerminalSurfaceLaunchDependencies,
        renderConfigSerializer: @escaping @MainActor () -> Data?,
        mobileTerminalDataPlane: any MobileTerminalDataPlane =
            UnavailablePersistentMobileTerminalDataPlane(),
        topologyFailureReporter: @escaping @MainActor (String) -> Void = { _ in }
    ) -> TerminalClientComposition where Client: TerminalBackendClient & TerminalBackendTopologyMutating {
        let registry = TerminalBackendPresentationRegistry()
        let topologyAuthorizationGate = TerminalBackendTopologyAuthorizationGate()
        let topologyAdoptionRegistry = TerminalBackendTopologyAdoptionRegistry()
        let topologyMutationCoordinator = TerminalBackendTopologyMutationCoordinator(
            mutator: backendClient,
            failureReporter: topologyFailureReporter
        )
        let renderConfigSource = TerminalBackendRenderConfigSource(
            serializer: renderConfigSerializer
        )
        let remoteTmuxSurfaceRegistry: TerminalBackendRemoteTmuxSurfaceRegistry? = {
            guard let externalService = backendClient as?
                    any TerminalBackendExternalTerminalServing,
                  let producerSourceService = backendClient as?
                    any TerminalBackendRemoteTmuxProducerSourceServing else { return nil }
                let recoveringClient = backendClient as?
                    any TerminalBackendFrontendConnectionRecovering
                return TerminalBackendRemoteTmuxSurfaceRegistry(
                    service: externalService,
                    producerSourceService: producerSourceService,
                    recoveryHandler: {
                        await recoveringClient?.recoverFrontendConnection()
                    }
                )
        }()
        let factory = PersistentTerminalPanelFactory(
            presentationDependencies: presentationDependencies,
            backendClient: backendClient,
            launchResolver: TerminalSurfaceLaunchResolver(dependencies: launchDependencies),
            presentationRegistry: registry,
            renderConfigSource: renderConfigSource,
            topologyAuthorizationGate: topologyAuthorizationGate,
            remoteTmuxSurfaceRegistry: remoteTmuxSurfaceRegistry
        )
        let nativeBrowserPresentationRegistry =
            TerminalBackendNativeBrowserPresentationRegistry()
        let nativeBrowserRuntimeCoordinator =
            (backendClient as? any TerminalBackendFrontendNativeBrowserServing).map {
                let recoveringClient = backendClient as?
                    any TerminalBackendFrontendConnectionRecovering
                return TerminalBackendNativeBrowserRuntimeCoordinator(
                    service: $0,
                    presentationRegistry: nativeBrowserPresentationRegistry,
                    failureReporter: topologyFailureReporter,
                    recoveryHandler: {
                        await recoveringClient?.recoverFrontendConnection()
                    }
                )
            }
        return TerminalClientComposition(
            terminalPanelFactory: factory,
            terminalBackendClient: backendClient,
            terminalPresentationRegistry: registry,
            terminalBackendTopologyAuthorizationGate: topologyAuthorizationGate,
            terminalBackendTopologyMutationCoordinator: topologyMutationCoordinator,
            terminalBackendTopologyAdoptionRegistry: topologyAdoptionRegistry,
            nativeBrowserPresentationRegistry: nativeBrowserPresentationRegistry,
            nativeBrowserRuntimeCoordinator: nativeBrowserRuntimeCoordinator,
            remoteTmuxSurfaceRegistry: remoteTmuxSurfaceRegistry,
            browserEndpointFactory: NativeTerminalBackendBrowserEndpointFactory(
                presentationRegistry: nativeBrowserPresentationRegistry,
                claimedSourceURL: { [nativeBrowserRuntimeCoordinator] surfaceID in
                    nativeBrowserRuntimeCoordinator?.claimedSourceURL(surfaceID: surfaceID)
                }
            ),
            mobileTerminalDataPlane: mobileTerminalDataPlane,
            canonicalBrowserProjectionAvailable: true
        )
    }

    /// Authoritative snapshots used to import daemon terminals missing from Swift restore state.
    func canonicalSnapshots() async throws -> AsyncStream<TopologySnapshot>? {
        try await terminalBackendClient?.canonicalSnapshots()
    }

    /// Canonical topology changes with explicit connection loss and original
    /// transaction metadata retained for minimal UI reconciliation.
    func canonicalTopologyEvents() async throws -> AsyncStream<TerminalBackendTopologyStreamEvent>? {
        try await terminalBackendClient?.canonicalTopologyEvents()
    }

    /// Reader-specific daemon activity used to derive sidebar unread state.
    func terminalActivitySnapshots() async -> AsyncStream<BackendTerminalActivitySnapshot>? {
        await terminalBackendClient?.terminalActivitySnapshots()
    }
}

/// Exact, one-shot authorization for a client-owned loading surface to become
/// a daemon-owned terminal at the same stable workspace and surface IDs.
/// Arbitrary panel-kind changes remain rejected by canonical preflight.
@MainActor
final class TerminalBackendTopologyAdoptionRegistry {
    struct Key: Hashable, Sendable {
        let workspaceID: UUID
        let surfaceID: UUID
    }

    private var permitTokens: [Key: UUID] = [:]

    @discardableResult
    func beginCloudTerminalAdoption(
        workspaceID: UUID,
        surfaceID: UUID
    ) -> UUID {
        let token = UUID()
        permitTokens[Key(workspaceID: workspaceID, surfaceID: surfaceID)] = token
        return token
    }

    func permitsCloudTerminalAdoption(
        workspaceID: UUID,
        surfaceID: UUID
    ) -> Bool {
        permitTokens[Key(workspaceID: workspaceID, surfaceID: surfaceID)] != nil
    }

    func cancelCloudTerminalAdoption(
        workspaceID: UUID,
        surfaceID: UUID,
        token: UUID
    ) {
        let key = Key(workspaceID: workspaceID, surfaceID: surfaceID)
        guard permitTokens[key] == token else { return }
        permitTokens.removeValue(forKey: key)
    }

    @discardableResult
    func consumeCloudTerminalAdoption(
        workspaceID: UUID,
        surfaceID: UUID
    ) -> Bool {
        permitTokens.removeValue(
            forKey: Key(workspaceID: workspaceID, surfaceID: surfaceID)
        ) != nil
    }
}
