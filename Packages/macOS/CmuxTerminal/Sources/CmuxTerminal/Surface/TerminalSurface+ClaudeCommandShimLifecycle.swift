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
                self.claudeCommandShimInstallTask = nil
                self.claudeCommandShimCompletionTask = nil
                self.claudeCommandShimDeadlineTask?.cancel()
                self.claudeCommandShimDeadlineTask = nil
                // The deadline may have already released spawn without the
                // shim; the late result still serves future runtime creations.
                guard !self.claudeCommandShimInstallCompleted else { return }
                self.claudeCommandShimInstallCompleted = true
                let source = self.claudeCommandShimPendingCreationSource ?? source
                self.claudeCommandShimPendingCreationSource = nil
                self.resumeSurfaceCreationAfterClaudeCommandShimReady(view: view, source: source)
            }
            // Bounded, cancellable deadline (injected clock): the wrapper shim
            // is an optional PATH convenience, and a hung install (disk
            // pressure, starved queues) must never starve PTY spawn (#9769).
            let deadline = claudeCommandShimInstallDeadline
            let clock = claudeCommandShimInstallDeadlineClock
            claudeCommandShimDeadlineTask = Task { @MainActor [weak self, weak view] in
                try? await clock.sleep(for: deadline, tolerance: nil)
                guard !Task.isCancelled else { return }
                guard let self, !self.claudeCommandShimInstallCompleted else { return }
                self.claudeCommandShimInstallCompleted = true
                self.claudeCommandShimDeadlineTask = nil
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
        claudeCommandShimDeadlineTask?.cancel()
        claudeCommandShimDeadlineTask = nil
        claudeCommandShimPendingCreationSource = nil
        // A deadline-released spawn marks the install completed without a
        // shim so that one spawn is not starved. Once the in-flight install
        // is cancelled, that state must not become permanent: reopen the
        // gate so the next runtime creation (e.g. after an agent-hibernation
        // resume) attempts a fresh install instead of running shim-less
        // forever.
        if claudeCommandShim == nil {
            claudeCommandShimInstallCompleted = false
        }
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
