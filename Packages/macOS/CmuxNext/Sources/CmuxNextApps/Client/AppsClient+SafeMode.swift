public import Foundation

/// How a launch settled (`safe_mode.launch_settled {reason}`): its first frame and 10 seconds up,
/// or a clean quit.
public nonisolated enum LaunchSettleReason: String, Sendable {
    case frame, quit
}

/// Where this process's launch report to the supervisor is. The crash loop rule
/// (docs/cmux-next/extensions/safe-mode.md) is the daemon's; the app only says when it began and
/// when it settled, once per process, so a reconnect is never counted as a launch.
enum LaunchReport {
    case unreported
    /// Asked before the supervisor answered: sent on the first connection.
    case pending(entersSafeMode: Bool)
    /// Sent on the mount chain; the settle waits for it.
    case began(Task<Void, Never>?)
    case settled
}

extension AppsClient {
    /// The app launched: `safe_mode.launch_began` once, on the mount chain ahead of every mount,
    /// and with `entersSafeMode` (the key held at launch) `safe_mode.set {on: true}` right after it.
    /// Sent at once when the supervisor answers, else on the first connection.
    public func reportLaunchBegan(entersSafeMode: Bool) {
        guard case .unreported = launchReport else { return }
        launchReport = .pending(entersSafeMode: entersSafeMode)
        if availability.isAvailable { sendPendingLaunch() }
    }

    /// Sends the pending launch report (``connected()`` calls it before it mounts again).
    func sendPendingLaunch() {
        guard case .pending(let entersSafeMode) = launchReport else { return }
        enqueue { transport in
            _ = try? await transport.safeMode("safe_mode.launch_began", args: .object([:]), origin: .user, timeout: nil)
            guard entersSafeMode else { return }
            _ = try? await transport.safeMode("safe_mode.set", args: ["on": true], origin: .user, timeout: nil)
        }
        launchReport = .began(tail)
    }

    /// The launch settled: `safe_mode.launch_settled {reason}` once, after its began reached the
    /// supervisor; nothing when the launch never reported (no supervisor answered). Returns once
    /// the supervisor answered or `timeout` passed.
    public func reportLaunchSettled(_ reason: LaunchSettleReason, timeout: Duration? = nil) async {
        guard case .began(let began) = launchReport else { return }
        launchReport = .settled
        await began?.value
        _ = try? await transport.safeMode("safe_mode.launch_settled", args: ["reason": .string(reason.rawValue)],
                                          origin: .user, timeout: timeout)
    }

    /// `safe_mode.set {on}` with `origin` (entering from any origin; leaving only as the person on
    /// the verified connection, else the supervisor refuses with why). Answers the safe mode.
    public func setSafeMode(_ on: Bool, origin: AppOrigin) async throws(AppsClientError) -> AppJSON {
        if case .unavailable(let reason) = availability { throw .unavailable(reason) }
        do throws(AppsTransportError) {
            return try await transport.safeMode("safe_mode.set", args: ["on": .bool(on)], origin: origin, timeout: nil)
        } catch {
            throw .refused(error)
        }
    }
}
