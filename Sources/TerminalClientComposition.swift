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

    init(
        terminalPanelFactory: any TerminalPanelCreating,
        terminalBackendClient: (any TerminalBackendClient)? = nil,
        terminalPresentationRegistry: TerminalBackendPresentationRegistry? = nil,
        terminalBackendTopologyAuthorizationGate: TerminalBackendTopologyAuthorizationGate? = nil,
        terminalBackendTopologyMutationCoordinator: TerminalBackendTopologyMutationCoordinator? = nil
    ) {
        self.terminalPanelFactory = terminalPanelFactory
        self.terminalBackendClient = terminalBackendClient
        self.terminalPresentationRegistry = terminalPresentationRegistry
        self.terminalBackendTopologyAuthorizationGate = terminalBackendTopologyAuthorizationGate
        self.terminalBackendTopologyMutationCoordinator = terminalBackendTopologyMutationCoordinator
    }

    static func embedded() -> TerminalClientComposition {
        TerminalClientComposition(
            terminalPanelFactory: EmbeddedTerminalPanelFactory(
                dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies
            )
        )
    }

    static func persistent(
        backendClient: any TerminalBackendClient,
        dependencies: TerminalSurfaceRuntimeDependencies,
        topologyFailureReporter: @escaping @MainActor (String) -> Void = { _ in }
    ) -> TerminalClientComposition {
        let registry = TerminalBackendPresentationRegistry()
        let topologyAuthorizationGate = TerminalBackendTopologyAuthorizationGate()
        let topologyMutationCoordinator = TerminalBackendTopologyMutationCoordinator(
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
}
