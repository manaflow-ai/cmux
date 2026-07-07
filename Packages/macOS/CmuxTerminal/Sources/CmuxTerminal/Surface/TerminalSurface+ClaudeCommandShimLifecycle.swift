import Foundation

extension TerminalSurface {
    @MainActor
    func claudeCommandShimStateForSurface(
        view: any TerminalSurfaceNativeViewing,
        source: RuntimeSurfaceCreationSource
    ) -> (isReady: Bool, shim: ClaudeCommandShim?) {
        guard let wrapperURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux-claude-wrapper") else {
            claudeCommandShimInstallCompleted = true
            return (true, nil)
        }

        if claudeCommandShimInstallCompleted {
            return (true, claudeCommandShim)
        }

        claudeCommandShimPendingCreationSource =
            (claudeCommandShimPendingCreationSource ?? source).promoted(with: source)

        if claudeCommandShimInstallTask == nil {
            let surfaceId = id
            // Explicit captures and arguments: the region-based isolation
            // checker cannot analyze the legacy closure's implicit captures
            // and in-closure default-argument evaluation (same effective body).
            let runtimeFilesystem = runtimeFilesystem
            let temporaryDirectory = runtimeFilesystem.claudeCommandShimTemporaryDirectory
            #if compiler(>=6.2)
            let installOperation: @concurrent @Sendable () async -> ClaudeCommandShim? = {
                [wrapperURL, surfaceId, temporaryDirectory, runtimeFilesystem] in
                await runtimeFilesystem.installClaudeCommandShim(wrapperURL, surfaceId, temporaryDirectory)
            }
            #else
            let installOperation: @Sendable () async -> ClaudeCommandShim? = {
                [wrapperURL, surfaceId, temporaryDirectory, runtimeFilesystem] in
                await runtimeFilesystem.installClaudeCommandShim(wrapperURL, surfaceId, temporaryDirectory)
            }
            #endif
            let installTask = Task.detached(priority: .utility, operation: installOperation)
            claudeCommandShimInstallTask = installTask
            claudeCommandShimCompletionTask = Task { @MainActor [weak self, weak view] in
                let shim = await installTask.value
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.claudeCommandShim = shim
                self.claudeCommandShimInstallCompleted = true
                self.claudeCommandShimInstallTask = nil
                self.claudeCommandShimCompletionTask = nil
                let source = self.claudeCommandShimPendingCreationSource ?? source
                self.claudeCommandShimPendingCreationSource = nil
                self.resumeSurfaceCreationAfterClaudeCommandShimReady(view: view, source: source)
            }
        }

        return (false, nil)
    }

    @MainActor
    func cancelClaudeCommandShimInstallLifecycle() {
        claudeCommandShimCompletionTask?.cancel()
        claudeCommandShimCompletionTask = nil
        claudeCommandShimInstallTask?.cancel()
        claudeCommandShimInstallTask = nil
        claudeCommandShimPendingCreationSource = nil
    }

    @MainActor
    func resumeSurfaceCreationAfterClaudeCommandShimReady(
        view: (any TerminalSurfaceNativeViewing)?,
        source: RuntimeSurfaceCreationSource
    ) {
        guard allowsRuntimeSurfaceCreation(), surface == nil else { return }

        if let view, view.window != nil {
            createSurface(for: view, source: source)
        } else if let attachedView, attachedView.window != nil {
            createSurface(for: attachedView, source: source)
        } else {
            scheduleHeadlessRuntimeStartIfNeeded(reason: "claude-shim-ready", source: source)
        }
    }
}
