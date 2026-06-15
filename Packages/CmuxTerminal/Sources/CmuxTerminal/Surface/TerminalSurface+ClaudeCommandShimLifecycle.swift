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

        if claudeCommandShimInstallTask == nil {
            let surfaceId = id
            // Explicit captures and arguments: the region-based isolation
            // checker cannot analyze the legacy closure's implicit captures
            // and in-closure default-argument evaluation (same effective body).
            let temporaryDirectory = FileManager.default.temporaryDirectory
            let installOperation: @Sendable () async -> ClaudeCommandShim? = { [wrapperURL, surfaceId, temporaryDirectory] in
                TerminalSurface.installClaudeCommandShimIfPossible(
                    wrapperURL: wrapperURL,
                    surfaceId: surfaceId,
                    temporaryDirectory: temporaryDirectory,
                    fileManager: .default
                )
            }
            let installTask = Task.detached(priority: .utility, operation: installOperation)
            claudeCommandShimInstallTask = installTask
            Task { @MainActor [weak self, weak view] in
                let shim = await installTask.value
                guard let self else { return }
                self.claudeCommandShim = shim
                self.claudeCommandShimInstallCompleted = true
                self.claudeCommandShimInstallTask = nil
                guard self.allowsRuntimeSurfaceCreation(), self.surface == nil else { return }
                if let view, view.window != nil {
                    self.createSurface(for: view, source: source)
                } else if let attachedView = self.attachedView, attachedView.window != nil {
                    self.createSurface(for: attachedView, source: source)
                } else {
                    self.scheduleHeadlessRuntimeStartIfNeeded(reason: "claude-shim-ready")
                }
            }
        }

        return (false, nil)
    }
}
