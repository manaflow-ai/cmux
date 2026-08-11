import Foundation

struct TerminalSurfaceAgentCommandShimPreparation {
    let commandShims: AgentCommandShimSet?
    let launchResourceSnapshot: TerminalSurfaceLaunchResourceSnapshot
}

extension TerminalSurface {
    @MainActor
    func agentCommandShimPreparationForSurface(
        view: any TerminalSurfaceNativeViewing,
        source: RuntimeSurfaceCreationSource
    ) -> TerminalSurfaceAgentCommandShimPreparation? {
        guard let embeddedRuntime else {
            let preparation = TerminalSurfaceAgentCommandShimPreparation(
                commandShims: nil,
                launchResourceSnapshot: .unavailable
            )
            agentCommandShimPreparation = preparation
            return preparation
        }
        guard let wrapperDirectoryURL = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true) else {
            let preparation = TerminalSurfaceAgentCommandShimPreparation(
                commandShims: nil,
                launchResourceSnapshot: .unavailable
            )
            agentCommandShimPreparation = preparation
            return preparation
        }

        if let agentCommandShimPreparation {
            return agentCommandShimPreparation
        }

        agentCommandShimPendingCreationSource =
            (agentCommandShimPendingCreationSource ?? source).promoted(with: source)

        if agentCommandShimInstallTask == nil {
            let runtimeFilesystem = embeddedRuntime.runtimeFilesystem
            let launchResourceProvider = embeddedRuntime.launchResourceProvider
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
                    launchResourceProvider,
                    installLease,
                    installResultGate
                ] in
                if let launchResourceProvider {
                    _ = await launchResourceProvider.snapshot()
                }
                guard !Task.isCancelled else { return nil }
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
                    launchResourceProvider,
                    installLease,
                    installResultGate
                ] in
                if let launchResourceProvider {
                    _ = await launchResourceProvider.snapshot()
                }
                guard !Task.isCancelled else { return nil }
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
            agentCommandShimCompletionTask = Task { @MainActor [weak self, weak view, runtimeFilesystem, launchResourceProvider] in
                let launchResourceSnapshot: TerminalSurfaceLaunchResourceSnapshot
                if let launchResourceProvider {
                    launchResourceSnapshot = await launchResourceProvider.snapshot()
                } else {
                    launchResourceSnapshot = .unavailable
                }
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
                self.agentCommandShimInstallTask = nil
                self.agentCommandShimCompletionTask = nil
                self.agentCommandShimInstallLease = nil
                self.agentCommandShimInstallResultGate = nil
                self.agentCommandShimDeadlineTask?.cancel()
                self.agentCommandShimDeadlineTask = nil
                guard self.agentCommandShimPreparation == nil else { return }
                self.agentCommandShimPreparation = TerminalSurfaceAgentCommandShimPreparation(
                    commandShims: shims,
                    launchResourceSnapshot: launchResourceSnapshot
                )
                let source = self.agentCommandShimPendingCreationSource ?? source
                self.agentCommandShimPendingCreationSource = nil
                self.resumeSurfaceCreationAfterAgentCommandShimsReady(view: view, source: source)
            }
            // Bounded, cancellable deadline (injected clock): command shims
            // are an optional PATH convenience, and a hung install must never
            // starve PTY spawn (#9769).
            let deadline = embeddedRuntime.agentCommandShimInstallDeadline
            let clock = embeddedRuntime.agentCommandShimInstallDeadlineClock
            agentCommandShimDeadlineTask = Task { @MainActor [weak self, weak view, launchResourceProvider] in
                try? await clock.sleep(for: deadline, tolerance: nil)
                let launchResourceSnapshot: TerminalSurfaceLaunchResourceSnapshot
                if let launchResourceProvider {
                    launchResourceSnapshot = await launchResourceProvider.completedSnapshot()
                        ?? .unavailable
                } else {
                    launchResourceSnapshot = .unavailable
                }
                guard !Task.isCancelled else { return }
                guard let self, self.agentCommandShimPreparation == nil else { return }
                guard self.agentCommandShimInstallResultGate?.expire() == true else {
                    return
                }
                self.agentCommandShimInstallLease?.invalidate()
                self.agentCommandShimInstallTask?.cancel()
                self.agentCommandShimPreparation = TerminalSurfaceAgentCommandShimPreparation(
                    commandShims: nil,
                    launchResourceSnapshot: launchResourceSnapshot
                )
                self.agentCommandShimDeadlineTask = nil
                let source = self.agentCommandShimPendingCreationSource ?? source
                self.agentCommandShimPendingCreationSource = nil
                self.resumeSurfaceCreationAfterAgentCommandShimsReady(view: view, source: source)
            }
        }

        return nil
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
        if agentCommandShimPreparation?.commandShims == nil {
            agentCommandShimPreparation = nil
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
