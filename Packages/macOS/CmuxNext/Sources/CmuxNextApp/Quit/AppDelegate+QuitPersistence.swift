import CmuxNextControl

extension AppDelegate {
    /// The exit's steps: `prepare` waits on no disk, so the deadline is armed at once; the state files' queued
    /// saves are awaited beside the Home cache's write, after it (tests inject the deadline and the end).
    static func secondSignalExit(_ services: @escaping @MainActor () -> AppServices?, armDeadline: ((Duration) -> Void)? = nil,
                                end: (@MainActor () -> Void)? = nil) -> ForcedQuitExit {
        ForcedQuitExit(prepare: {
            services()?.crashRecovery.applicationWillTerminate()
            AppProcessRoot.shared.hangReports?.applicationWillTerminate()
            services()?.home.applicationWillTerminate()
        }, save: {
            guard let services = services() else { return }
            async let files: Void = services.stateFilesDrained()
            await services.home.flushCacheForQuit()
            await services.windows.recordSaver.launchRecord.flush()
            await files
        }, armDeadline: armDeadline, deadlineEnd: services()?.quitDeadlineEnd(), end: end)
    }
}
