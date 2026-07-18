import CmuxTerminal
import Foundation

/// Constructs terminals whose PTY, parser, and renderer are owned by the persistent backend.
///
/// This factory is installed only when the backend feature gate is enabled. It intentionally
/// has no embedded fallback: a backend failure must stay visible and fail closed instead of
/// silently moving terminal ownership back into the Swift app process.
@MainActor
final class PersistentTerminalPanelFactory: TerminalPanelCreating {
    private let dependencies: TerminalSurfaceRuntimeDependencies
    private let backendClient: any TerminalBackendClient
    private let launchResolver: TerminalSurfaceLaunchResolver
    private let presentationRegistry: TerminalBackendPresentationRegistry
    private let renderConfigSource: TerminalBackendRenderConfigSource
    private let topologyAuthorizationGate: TerminalBackendTopologyAuthorizationGate

    init(
        dependencies: TerminalSurfaceRuntimeDependencies,
        backendClient: any TerminalBackendClient,
        launchResolver: TerminalSurfaceLaunchResolver,
        presentationRegistry: TerminalBackendPresentationRegistry,
        renderConfigSource: TerminalBackendRenderConfigSource,
        topologyAuthorizationGate: TerminalBackendTopologyAuthorizationGate
    ) {
        self.dependencies = dependencies
        self.backendClient = backendClient
        self.launchResolver = launchResolver
        self.presentationRegistry = presentationRegistry
        self.renderConfigSource = renderConfigSource
        self.topologyAuthorizationGate = topologyAuthorizationGate
    }

    func makeTerminalPanel(_ request: TerminalPanelCreationRequest) -> TerminalPanel {
        let launchRequest = TerminalSurfaceLaunchRequest(
            workspaceID: request.workspaceId,
            surfaceID: request.id,
            configTemplate: request.configTemplate,
            workingDirectory: request.workingDirectory,
            portOrdinal: request.portOrdinal,
            initialCommand: request.initialCommand,
            initialInput: request.initialInput,
            initialEnvironmentOverrides: request.initialEnvironmentOverrides,
            additionalEnvironment: request.additionalEnvironment
        )
        let runtime = PersistentTerminalExternalRuntime(
            client: backendClient,
            launchResolver: launchResolver,
            launchRequest: launchRequest,
            presentationRegistry: presentationRegistry,
            renderConfigSource: renderConfigSource,
            presentationConfigOverrides: rendererConfigOverrides(for: request),
            topologyAuthorizationGate: topologyAuthorizationGate
        )
        let panel = TerminalPanel(
            request: request,
            dependencies: dependencies,
            externalRuntime: runtime
        )
        _ = presentationRegistry.mountCompositor(
            surfaceID: request.id,
            in: panel.surface.compositorHostView
        )
        return panel
    }

    private func rendererConfigOverrides(for request: TerminalPanelCreationRequest) -> Data {
        guard let baseFontSize = request.configTemplate?.fontSize,
              baseFontSize.isFinite,
              baseFontSize > 0 else { return Data() }
        let runtimeFontSize = CmuxSurfaceConfigTemplate.runtimeFontSize(
            fromBasePoints: baseFontSize,
            percent: dependencies.globalFontMagnificationPercent()
        )
        return Data("font-size = \(runtimeFontSize)\n".utf8)
    }
}
