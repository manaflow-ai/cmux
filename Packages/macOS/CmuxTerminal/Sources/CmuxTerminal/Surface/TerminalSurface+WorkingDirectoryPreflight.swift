import Foundation

// MARK: - Off-main working-directory preflight (#21260)

extension TerminalSurface {
    /// The working directory this surface requests for its runtime.
    func resolvedRuntimeWorkingDirectory(baseConfig: CmuxSurfaceConfigTemplate?) -> String? {
        if let workingDirectory, !workingDirectory.isEmpty {
            return workingDirectory
        }
        return baseConfig?.workingDirectory
    }

    /// The working directory native creation passes to `ghostty_surface_new`.
    ///
    /// A directory whose off-main open failed is withheld. Ghostty falls back
    /// to the same inherited directory when its own open fails, so this only
    /// stops the main thread from retrying a path that already stalled.
    @MainActor
    func openableRuntimeWorkingDirectory(baseConfig: CmuxSurfaceConfigTemplate?) -> String? {
        guard let path = resolvedRuntimeWorkingDirectory(baseConfig: baseConfig) else { return nil }
        if let prepared = preparedRuntimeWorkingDirectory,
           prepared.path == path,
           !prepared.isOpenable {
            return nil
        }
        return path
    }

    /// Returns whether native creation may open its working directory now.
    ///
    /// `ghostty_surface_new` opens the working directory on the main thread.
    /// While restored agents start in a burst, that `openat` can stall behind
    /// their filesystem work and hang the UI and surface commands. Each native
    /// creation therefore opens the directory off the main actor first and
    /// resumes once the lookup returns. A slow directory delays only its own
    /// terminal.
    @MainActor
    func runtimeWorkingDirectoryStateForSurface(
        view: any TerminalSurfaceNativeViewing,
        source: RuntimeSurfaceCreationSource
    ) -> Bool {
        guard let path = resolvedRuntimeWorkingDirectory(baseConfig: configTemplate),
              !path.isEmpty else {
            return true
        }
        if preparedRuntimeWorkingDirectory?.path == path {
            return true
        }

        runtimeWorkingDirectoryPreflightPendingCreationSource =
            (runtimeWorkingDirectoryPreflightPendingCreationSource ?? source).promoted(with: source)
        guard runtimeWorkingDirectoryPreflightTask == nil else { return false }

        let prepareWorkingDirectory = runtimeFilesystem.prepareWorkingDirectory
        #if compiler(>=6.2)
        let prepareOperation: @concurrent @Sendable () async -> Bool = {
            [prepareWorkingDirectory, path] in
            await prepareWorkingDirectory(path)
        }
        #else
        let prepareOperation: @Sendable () async -> Bool = {
            [prepareWorkingDirectory, path] in
            await prepareWorkingDirectory(path)
        }
        #endif
        let prepareTask = Task.detached(priority: .userInitiated, operation: prepareOperation)
        runtimeWorkingDirectoryPreflightTask = Task { @MainActor [weak self, weak view] in
            let isOpenable = await prepareTask.value
            guard let self else { return }
            self.runtimeWorkingDirectoryPreflightTask = nil
            // A withdrawn request keeps nothing: a later creation opens again.
            guard let source = self.runtimeWorkingDirectoryPreflightPendingCreationSource else { return }
            self.runtimeWorkingDirectoryPreflightPendingCreationSource = nil
            self.preparedRuntimeWorkingDirectory = TerminalSurfacePreparedWorkingDirectory(
                path: path,
                isOpenable: isOpenable
            )
            self.resumeDeferredRuntimeSurfaceCreation(
                view: view,
                source: source,
                reason: "working-directory-ready"
            )
        }
        return false
    }

    /// Withdraws a pending creation and forgets any prepared directory.
    @MainActor
    func cancelRuntimeWorkingDirectoryPreflight() {
        runtimeWorkingDirectoryPreflightPendingCreationSource = nil
        preparedRuntimeWorkingDirectory = nil
    }
}
