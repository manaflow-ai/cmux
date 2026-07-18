import CmuxTerminal
import CmuxTerminalBackend

/// Process-scoped terminal client dependencies shared by every window,
/// workspace, and Dock in one cmux process.
@MainActor
final class TerminalClientComposition {
    let terminalPanelFactory: any TerminalPanelCreating
    let terminalBackendClient: (any TerminalBackendClient)?
    let terminalPresentationRegistry: TerminalBackendPresentationRegistry?
    let terminalBackendTopologyAuthorizationGate: TerminalBackendTopologyAuthorizationGate?
    let terminalBackendTopologyMutationCoordinator: TerminalBackendTopologyMutationCoordinator?
    let browserEndpointFactory: any TerminalBackendBrowserEndpointCreating

    init(
        terminalPanelFactory: any TerminalPanelCreating,
        terminalBackendClient: (any TerminalBackendClient)? = nil,
        terminalPresentationRegistry: TerminalBackendPresentationRegistry? = nil,
        terminalBackendTopologyAuthorizationGate: TerminalBackendTopologyAuthorizationGate? = nil,
        terminalBackendTopologyMutationCoordinator: TerminalBackendTopologyMutationCoordinator? = nil,
        browserEndpointFactory: (any TerminalBackendBrowserEndpointCreating)? = nil
    ) {
        self.terminalPanelFactory = terminalPanelFactory
        self.terminalBackendClient = terminalBackendClient
        self.terminalPresentationRegistry = terminalPresentationRegistry
        self.terminalBackendTopologyAuthorizationGate = terminalBackendTopologyAuthorizationGate
        self.terminalBackendTopologyMutationCoordinator = terminalBackendTopologyMutationCoordinator
        self.browserEndpointFactory = browserEndpointFactory
            ?? UnsupportedTerminalBackendBrowserEndpointFactory()
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
        dependencies: TerminalSurfaceRuntimeDependencies,
        topologyFailureReporter: @escaping @MainActor (String) -> Void = { _ in }
    ) -> TerminalClientComposition where Client: TerminalBackendClient & TerminalBackendTopologyMutating {
        let registry = TerminalBackendPresentationRegistry()
        let topologyAuthorizationGate = TerminalBackendTopologyAuthorizationGate()
        let topologyMutationCoordinator = TerminalBackendTopologyMutationCoordinator(
            mutator: backendClient,
            failureReporter: topologyFailureReporter
        )
        let renderConfigSource = TerminalBackendRenderConfigSource {
            GhosttyApp.shared.serializedTerminalRendererConfig()
        }
        let factory = PersistentTerminalPanelFactory(
            dependencies: dependencies,
            backendClient: backendClient,
            launchResolver: TerminalSurfaceLaunchResolver(dependencies: dependencies),
            presentationRegistry: registry,
            renderConfigSource: renderConfigSource,
            topologyAuthorizationGate: topologyAuthorizationGate
        )
        return TerminalClientComposition(
            terminalPanelFactory: factory,
            terminalBackendClient: backendClient,
            terminalPresentationRegistry: registry,
            terminalBackendTopologyAuthorizationGate: topologyAuthorizationGate,
            terminalBackendTopologyMutationCoordinator: topologyMutationCoordinator
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
