import Foundation

extension TerminalSurface {
    @MainActor
    func agentCommandShimStateForSurface(
        view: any TerminalSurfaceNativeViewing,
        source: RuntimeSurfaceCreationSource
    ) -> (isReady: Bool, shims: AgentCommandShimSet?) {
        guard let embeddedRuntime else {
            agentCommandShimInstallCompleted = true
            return (true, nil)
        }
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
            let runtimeFilesystem = embeddedRuntime.runtimeFilesystem
            let surfaceId = id
            // Explicit captures and arguments: the region-based isolation
            // checker cannot analyze the legacy closure's implicit captures
            // and in-closure default-argument evaluation.
            let temporaryDirectory = runtimeFilesystem.agentCommandShimTemporaryDirectory
            let installLease = TerminalSurfaceCommandShimInstallLease(
                gate: runtimeFilesystem.agentCommandShimInstallGate
            )
            let installResultGate = TerminalSurfaceCommandShimInstallResultGate()
            agentCommandShimInstallLease = installLease
            agentCommandShimInstallResultGate = installResultGate
            #if compiler(>=6.2)
            let installOperation: @concurrent @Sendable () async -> AgentCommandShimSet? = {
                [
                    wrapperDirectoryURL,
                    surfaceId,
                    temporaryDirectory,
                    runtimeFilesystem,
                    installLease,
                    installResultGate
                ] in
                guard let installToken = await installLease.acquire() else {
                    return nil
                }
                defer {
                    installLease.release(installToken)
                }
                guard !Task.isCancelled else { return nil }
                let shims = await runtimeFilesystem.installAgentCommandShims(
                    wrapperDirectoryURL,
                    surfaceId,
                    temporaryDirectory
                )
                guard installResultGate.acceptResult() else {
                    if let shims {
                        await runtimeFilesystem.removeAgentCommandShims(shims)
                    }
                    return nil
                }
                return shims
            }
            #else
            let installOperation: @Sendable () async -> AgentCommandShimSet? = {
                [
                    wrapperDirectoryURL,
                    surfaceId,
                    temporaryDirectory,
                    runtimeFilesystem,
                    installLease,
                    installResultGate
                ] in
                guard let installToken = await installLease.acquire() else {
                    return nil
                }
                defer {
                    installLease.release(installToken)
                }
                guard !Task.isCancelled else { return nil }
                let shims = await runtimeFilesystem.installAgentCommandShims(
                    wrapperDirectoryURL,
                    surfaceId,
                    temporaryDirectory
                )
                guard installResultGate.acceptResult() else {
                    if let shims {
                        await runtimeFilesystem.removeAgentCommandShims(shims)
                    }
                    return nil
                }
                return shims
            }
            #endif
            let installTask = Task.detached(priority: .utility, operation: installOperation)
            agentCommandShimInstallTask = installTask
            agentCommandShimCompletionTask = Task { @MainActor [weak self, weak view, runtimeFilesystem] in
                let shims = await installTask.value
                guard !Task.isCancelled else {
                    if let shims {
                        await runtimeFilesystem.removeAgentCommandShims(shims)
                    }
                    return
                }
                guard let self else {
                    if let shims {
                        await runtimeFilesystem.removeAgentCommandShims(shims)
                    }
                    return
                }
                self.agentCommandShims = shims
                self.agentCommandShimInstallTask = nil
                self.agentCommandShimCompletionTask = nil
                self.agentCommandShimInstallLease = nil
                self.agentCommandShimInstallResultGate = nil
                self.agentCommandShimDeadlineTask?.cancel()
                self.agentCommandShimDeadlineTask = nil
                guard !self.agentCommandShimInstallCompleted else { return }
                self.agentCommandShimInstallCompleted = true
                let source = self.agentCommandShimPendingCreationSource ?? source
                self.agentCommandShimPendingCreationSource = nil
                self.resumeSurfaceCreationAfterAgentCommandShimsReady(view: view, source: source)
            }
            // Bounded, cancellable deadline (injected clock): command shims
            // are an optional PATH convenience, and a hung install must never
            // starve PTY spawn (#9769).
            let deadline = embeddedRuntime.agentCommandShimInstallDeadline
            let clock = embeddedRuntime.agentCommandShimInstallDeadlineClock
            agentCommandShimDeadlineTask = Task { @MainActor [weak self, weak view] in
                try? await clock.sleep(for: deadline, tolerance: nil)
                guard !Task.isCancelled else { return }
                guard let self, !self.agentCommandShimInstallCompleted else { return }
                guard self.agentCommandShimInstallResultGate?.expire() == true else {
                    return
                }
                self.agentCommandShimInstallLease?.invalidate()
                self.agentCommandShimInstallTask?.cancel()
                self.agentCommandShimInstallCompleted = true
                self.agentCommandShimDeadlineTask = nil
                let source = self.agentCommandShimPendingCreationSource ?? source
                self.agentCommandShimPendingCreationSource = nil
                self.resumeSurfaceCreationAfterAgentCommandShimsReady(view: view, source: source)
            }
        }

        return (false, nil)
    }

    @MainActor
    func cancelAgentCommandShimInstallLifecycle() {
        agentCommandShimInstallResultGate?.expire()
        agentCommandShimInstallResultGate = nil
        agentCommandShimInstallLease?.invalidate()
        agentCommandShimInstallLease = nil
        agentCommandShimCompletionTask?.cancel()
        agentCommandShimCompletionTask = nil
        agentCommandShimInstallTask?.cancel()
        agentCommandShimInstallTask = nil
        agentCommandShimDeadlineTask?.cancel()
        agentCommandShimDeadlineTask = nil
        agentCommandShimPendingCreationSource = nil
        // A deadline-released spawn marks the install completed without
        // shims. Reopen the gate after cancelling that install so a later
        // runtime generation can try again.
        if agentCommandShims == nil {
            agentCommandShimInstallCompleted = false
        }
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
