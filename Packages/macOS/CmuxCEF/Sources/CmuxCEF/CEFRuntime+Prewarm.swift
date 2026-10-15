public import Foundation

extension CEFRuntime {
    /// The page the warm-up loads: an empty document that still needs a
    /// renderer process (the initial about:blank commits without a real load).
    nonisolated static let prewarmURL = URL(string: "data:text/html;charset=utf-8,")!

    /// Opens one hidden page in `profile`'s store, waits until it loaded or
    /// failed, and closes it.
    ///
    /// The first Chromium page pays for more than `CefInitialize`: the first
    /// renderer process launch and the network and storage services of its
    /// store (about 500 ms off the main thread). Loading a throwaway page at
    /// an idle moment moves that work out of the user's first page. Does
    /// nothing unless CEF is running with no page open or being created.
    /// - Parameters:
    ///   - profile: The cmux browser profile whose store the first page will likely use.
    ///   - timeout: How long to wait for the load before closing the page anyway.
    ///   - clock: Measures `timeout`.
    public func prewarmFirstPage<C: Clock>(
        profile: UUID,
        timeout: Duration = .seconds(10),
        clock: C = ContinuousClock()
    ) async where C.Duration == Duration {
        guard isRunning, !isShuttingDown, browsers.isEmpty, pendingWindows.isEmpty else { return }
        let started = ContinuousClock.now
        let browser = CEFBrowser(
            configuration: CEFBrowserConfiguration(profile: profile, initialURL: Self.prewarmURL),
            runtime: self
        )
        let waiter = CEFPrewarmWaiter()
        let timer = Task { @MainActor in
            try? await clock.sleep(for: timeout)
            waiter.finish(timedOut: !Task.isCancelled)
        }
        let timedOut = await waiter.wait {
            browser.onEvent = { event in
                if CEFPrewarmWaiter.ends(event) { waiter.finish(timedOut: false) }
            }
            browser.createNow()
        }
        timer.cancel()
        browser.onEvent = nil
        browser.close()
        logger.notice("CEF prewarm page \(timedOut ? "timed out" : "done", privacy: .public) in \(ContinuousClock.now - started, privacy: .public)")
    }
}

/// Resumes the warm-up once, on its page's first terminal event or the timeout.
@MainActor
final class CEFPrewarmWaiter {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    /// Whether `event` ends the warm-up page's load.
    nonisolated static func ends(_ event: CEFBrowserEvent) -> Bool {
        switch event {
        case .loadFinished, .loadFailed, .closed: true
        case .stateChanged(let state): state.rendererExit != nil
        case .loadStarted, .newBrowser, .closeRequested, .shim: false
        }
    }

    /// Runs `start`, then waits for ``finish(timedOut:)``.
    /// - Returns: Whether the wait ended by the timeout.
    func wait(_ start: () -> Void) async -> Bool {
        start()
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    /// Ends the wait; later calls do nothing.
    func finish(timedOut: Bool) {
        guard result == nil else { return }
        result = timedOut
        continuation?.resume(returning: timedOut)
        continuation = nil
    }
}
