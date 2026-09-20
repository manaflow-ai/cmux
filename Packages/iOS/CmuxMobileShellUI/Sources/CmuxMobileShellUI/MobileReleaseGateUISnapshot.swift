#if os(iOS) && DEBUG
import CMUXMobileCore
import UIKit
import notify

@MainActor
public struct MobileReleaseGateUISnapshot {
    private let timeoutClock: any Clock<Duration>

    public init(timeoutClock: any Clock<Duration> = ContinuousClock()) {
        self.timeoutClock = timeoutClock
    }

    /// UIKit hierarchy snapshots omit Ghostty's IOSurface pixels. Ask the
    /// simulator driver for a composited screen capture, then allow navigation
    /// back. The latency was already recorded at the presentation boundary.
    public func captureTerminal() async throws {
        let ready = "dev.cmux.ios.iroh-release-gate.ui-terminal-ready"
        let captured = "dev.cmux.ios.iroh-release-gate.ui-terminal-captured"
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var token: Int32 = 0
        guard notify_register_dispatch(captured, &token, .main, { _ in continuation.yield(()) }) == 0 else {
            throw MobileReleaseGateUIProbe.Failure.unavailable
        }
        defer {
            notify_cancel(token)
            continuation.finish()
        }
        notify_post(ready)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in stream { return }
                throw CancellationError()
            }
            group.addTask { [timeoutClock] in
                try await timeoutClock.sleep(for: .seconds(15))
                throw MobileReleaseGateUIProbe.Failure.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Supporting evidence from the actual isolated app window, captured after
    /// the measured boundary. Each name is overwritten, so storage is bounded.
    func capture(_ window: UIWindow?, name: String) {
        guard let window, !window.isHidden, !window.bounds.isEmpty else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let data = image.pngData(),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let destination = caches.appendingPathComponent("cmux-iroh-ui-\(name).png")
        // This is debug evidence consumed immediately after the release-gate
        // report. Complete the atomic write before returning so report copy
        // cannot race a detached writer.
        try? data.write(to: destination, options: .atomic)
    }
}
#endif
