import Foundation

extension TerminalSurface {
    @MainActor
    func agentCommandShimStateForSurface(
        view: any TerminalSurfaceNativeViewing,
        source: RuntimeSurfaceCreationSource
    ) -> (isReady: Bool, shims: AgentCommandShimSet?) {
        guard let wrapperDirectoryURL = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true) else {
            agentCommandShimInstallCompleted = true
            return (true, nil)
        }

        if agentCommandShimInstallCompleted {
            return (true, agentCommandShims)
        }

        agentCommandShimPendingCreationSource =
            (agentCommandShimPendingCreationSource ?? source).promoted(with: source)

        if agentCommandShimInstallTask == nil {
            let surfaceId = id
            // Explicit captures and arguments: the region-based isolation
            // checker cannot analyze the legacy closure's implicit captures
            // and in-closure default-argument evaluation.
            let runtimeFilesystem = runtimeFilesystem
            let temporaryDirectory = runtimeFilesystem.agentCommandShimTemporaryDirectory
            #if compiler(>=6.2)
            let installOperation: @concurrent @Sendable () async -> AgentCommandShimSet? = {
                [wrapperDirectoryURL, surfaceId, temporaryDirectory, runtimeFilesystem] in
                await runtimeFilesystem.installAgentCommandShims(
                    wrapperDirectoryURL,
                    surfaceId,
                    temporaryDirectory
                )
            }
            #else
            let installOperation: @Sendable () async -> AgentCommandShimSet? = {
                [wrapperDirectoryURL, surfaceId, temporaryDirectory, runtimeFilesystem] in
                await runtimeFilesystem.installAgentCommandShims(
                    wrapperDirectoryURL,
                    surfaceId,
                    temporaryDirectory
                )
            }
            #endif
            let installTask = Task.detached(priority: .utility, operation: installOperation)
            agentCommandShimInstallTask = installTask
            agentCommandShimCompletionTask = Task { @MainActor [weak self, weak view] in
                let shims = await installTask.value
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.agentCommandShims = shims
                self.agentCommandShimInstallCompleted = true
                self.agentCommandShimInstallTask = nil
                self.agentCommandShimCompletionTask = nil
                let source = self.agentCommandShimPendingCreationSource ?? source
                self.agentCommandShimPendingCreationSource = nil
                self.resumeSurfaceCreationAfterAgentCommandShimsReady(view: view, source: source)
            }
        }

        return (false, nil)
    }

    @MainActor
    func cancelAgentCommandShimInstallLifecycle() {
        agentCommandShimCompletionTask?.cancel()
        agentCommandShimCompletionTask = nil
        agentCommandShimInstallTask?.cancel()
        agentCommandShimInstallTask = nil
        agentCommandShimPendingCreationSource = nil
    }

    @MainActor
    func resumeSurfaceCreationAfterAgentCommandShimsReady(
        view: (any TerminalSurfaceNativeViewing)?,
        source: RuntimeSurfaceCreationSource
    ) {
        guard allowsRuntimeSurfaceCreation(), surface == nil else { return }

        if let view, view.window != nil {
            createSurface(for: view, source: source)
        } else if let attachedView, attachedView.window != nil {
            createSurface(for: attachedView, source: source)
        } else {
            scheduleHeadlessRuntimeStartIfNeeded(reason: "agent-shims-ready", source: source)
        }
    }
}
