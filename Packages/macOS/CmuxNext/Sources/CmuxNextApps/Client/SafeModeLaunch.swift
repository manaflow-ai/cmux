public import AppKit
import CmuxNextWakeups

/// The app's two calls for safe mode's crash loop rule and its launch key
/// (docs/cmux-next/extensions/safe-mode.md; the rule and the flag are the daemon's,
/// cmux-tui-core `apps/safe_mode.rs`): `safe_mode.launch_began` when the app starts,
/// `safe_mode.launch_settled {reason: "frame"}` 10 seconds after the launch settled
/// (the app's `LaunchSettle`: its first frame), and `{reason: "quit"}` on a clean quit (QuitCoordinator).
/// Shift held alone at launch starts in safe mode.
public nonisolated enum SafeModeLaunch {
    /// How long a settled launch stays up before it counts as settled.
    public static let settleDelay: Duration = .seconds(10)
    /// The quit's report waits at most this long for the daemon.
    public static let quitReportLimit: Duration = .milliseconds(300)

    /// Shift alone, as the launch reads the keys: Option+Shift is the launch that ignores
    /// customizations (`LaunchIdentity.ignoresCustomizations`), never safe mode; Caps Lock is ignored.
    public static func keyHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.shift, .control, .option, .command, .function]) == .shift
    }
}

extension AppsClient {
    /// Reports the launch with the keys held at launch (before ``start()``, so it goes ahead of every
    /// mount), and its settle ``SafeModeLaunch/settleDelay`` after `whenSettled` runs its work.
    public func reportLaunch(keys: NSEvent.ModifierFlags, whenSettled: @MainActor (@escaping @MainActor () -> Void) -> Void) {
        reportLaunchBegan(entersSafeMode: SafeModeLaunch.keyHeld(keys))
        whenSettled { [weak self] in
            self?.launchSettleTimer.schedule(after: SafeModeLaunch.settleDelay) { @MainActor [weak self] in
                await self?.reportLaunchSettled(.frame)
            }
        }
    }

    /// A clean quit settles this launch, waiting at most ``SafeModeLaunch/quitReportLimit``.
    public func reportCleanQuit() async {
        await reportLaunchSettled(.quit, timeout: SafeModeLaunch.quitReportLimit)
    }
}
