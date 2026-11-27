import Testing
@testable import CmuxMobileShell

// The lock is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
/// Settings → Require Face ID (review m5): Face ID's own sheet makes the
/// scene inactive and active again; returning from it must not ask again,
/// or a Cancel loops into another prompt. Only a return from the background
/// (and the launch) asks by itself. Serialized: the lock publishes to the
/// shared `NotificationRouter`.
@MainActor @Suite(.serialized) struct AppLockTests {
    @MainActor final class Checks {
        var count = 0
        var passes = false
    }

    func controller(_ checks: Checks, enabled: Bool = true) -> AppLockController {
        let lock = AppLockController(enabled: enabled)
        lock.authenticate = {
            { checks.count += 1; return checks.passes }
        }
        return lock
    }

    func settle(_ lock: AppLockController) async {
        for _ in 0..<200 where lock.evaluating { await Task.yield() }
    }

    @Test func aCancelledFaceIDDoesNotAskAgainOnItsOwn() async {
        let checks = Checks()
        let lock = controller(checks)
        #expect(lock.locked && lock.covered)
        // Launch: asks once.
        lock.sceneActivated()
        await settle(lock)
        #expect(checks.count == 1)
        #expect(lock.locked)
        // Face ID's sheet came and went (inactive → active), the user cancelled.
        lock.sceneDeactivated()
        lock.sceneActivated()
        await settle(lock)
        #expect(checks.count == 1)
        #expect(lock.locked)
        // The button asks.
        checks.passes = true
        lock.unlock()
        await settle(lock)
        #expect(checks.count == 2)
        #expect(!lock.locked && !lock.covered)
    }

    @Test func theBackgroundLocksAndTheReturnAsksOnce() async {
        let checks = Checks()
        checks.passes = true
        let lock = controller(checks)
        lock.sceneActivated()
        await settle(lock)
        #expect(!lock.locked)
        // The app switcher: covered while inactive, not locked.
        lock.sceneDeactivated()
        #expect(lock.covered && !lock.locked)
        lock.sceneActivated()
        #expect(!lock.covered)
        #expect(checks.count == 1)
        // The background locks; coming back asks.
        lock.sceneDeactivated()
        lock.sceneEnteredBackground()
        #expect(lock.locked)
        lock.sceneActivated()
        await settle(lock)
        #expect(checks.count == 2)
        #expect(!lock.locked)
    }

    @Test func offNeverCoversOrLocks() {
        let checks = Checks()
        let lock = controller(checks, enabled: false)
        lock.sceneDeactivated()
        lock.sceneEnteredBackground()
        #expect(!lock.covered)
        lock.sceneActivated()
        #expect(checks.count == 0)
        // Turning it off while locked unlocks.
        let on = controller(checks)
        on.setEnabled(false)
        #expect(!on.locked && !on.covered)
    }

    /// Issue 25687: `AppLock` builds a controller on every RootView body pass
    /// and SwiftUI keeps only the first. A discarded copy must not lock the
    /// notification router again after the user unlocked, or foreground
    /// replies wait in `PushReplies.drain()` until the next lock change.
    @Test func aReRenderAfterUnlockLeavesTheRouterUnlocked() async {
        let checks = Checks()
        checks.passes = true
        let lock = controller(checks)
        // `.onChange(of:initial:)` hands the kept controller the setting on appear.
        lock.setEnabled(true)
        #expect(NotificationRouter.shared.appLocked)
        lock.sceneActivated()
        await settle(lock)
        #expect(!lock.locked)
        #expect(!NotificationRouter.shared.appLocked)
        // The next body pass: a fresh `AppLock(enabled: true)` that SwiftUI discards.
        _ = AppLockController(enabled: true)
        #expect(!NotificationRouter.shared.appLocked)
        // The kept controller hears the unchanged setting again: still unlocked.
        lock.setEnabled(true)
        #expect(!lock.locked)
        #expect(!NotificationRouter.shared.appLocked)
    }

    @Test func theFirstSettingPublishesTheLockOnce() {
        let checks = Checks()
        let off = controller(checks, enabled: false)
        off.setEnabled(false)
        #expect(!NotificationRouter.shared.appLocked)
        let on = controller(checks)
        #expect(!NotificationRouter.shared.appLocked)
        on.setEnabled(true)
        #expect(NotificationRouter.shared.appLocked)
        on.setEnabled(false)
        #expect(!NotificationRouter.shared.appLocked)
    }
}
#endif
