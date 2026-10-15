public import CmuxBrowser
import CmuxCEF
import os

/// Lets `BrowserEngineWarmup` start Chromium at an idle moment before its
/// first page needs it. `availability` only checks that the runtime is
/// bundled, so nothing loads until a Chromium page is likely.
extension CEFBrowserEngineProvider: BrowserEngineWarming {
    /// `true` once `CefInitialize` has run.
    public var isRunning: Bool { runtime.isRunning }

    /// Maps the Chromium framework on a background thread; no Chromium code runs.
    public func preload() {
        runtime.preload()
    }

    /// Runs `CefInitialize`, then loads and closes one hidden page in the
    /// default profile so the first real page finds a renderer and its
    /// store's services started. A failure is left for the first page to report.
    /// - Parameter reason: Why a Chromium page is likely now.
    public func warmStart(reason: BrowserEngineWarmupReason) async {
        do {
            try await runtime.start()
            await runtime.prewarmFirstPage(profile: BrowserProfileRepository.builtInDefaultProfileID)
        } catch {
            Logger(subsystem: "com.cmuxterm.app", category: "cef").info(
                "Chromium warm start (\(reason.rawValue, privacy: .public)) failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
