import CmuxTerminal
import CmuxTerminalBackend

/// Process-scoped terminal client dependencies shared by every window,
/// workspace, and Dock in one cmux process.
@MainActor
final class TerminalClientComposition {
    let terminalPanelFactory: any TerminalPanelCreating
    let terminalBackendClient: (any TerminalBackendClient)?
    let terminalPresentationRegistry: TerminalBackendPresentationRegistry?

    init(
        terminalPanelFactory: any TerminalPanelCreating,
        terminalBackendClient: (any TerminalBackendClient)? = nil,
        terminalPresentationRegistry: TerminalBackendPresentationRegistry? = nil
    ) {
        self.terminalPanelFactory = terminalPanelFactory
        self.terminalBackendClient = terminalBackendClient
        self.terminalPresentationRegistry = terminalPresentationRegistry
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
        dependencies: TerminalSurfaceRuntimeDependencies
    ) -> TerminalClientComposition {
        let registry = TerminalBackendPresentationRegistry()
        let renderConfigSource = TerminalBackendRenderConfigSource {
            GhosttyApp.shared.serializedTerminalRendererConfig()
        }
        let factory = PersistentTerminalPanelFactory(
            dependencies: dependencies,
            backendClient: backendClient,
            launchResolver: TerminalSurfaceLaunchResolver(dependencies: dependencies),
            presentationRegistry: registry,
            renderConfigSource: renderConfigSource
        )
        return TerminalClientComposition(
            terminalPanelFactory: factory,
            terminalBackendClient: backendClient,
            terminalPresentationRegistry: registry
        )
    }

    /// Authoritative snapshots used to import daemon terminals missing from Swift restore state.
    func canonicalSnapshots() async -> AsyncStream<TopologySnapshot>? {
        await terminalBackendClient?.canonicalSnapshots()
    }
}
