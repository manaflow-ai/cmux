import CoreGraphics
@testable import CmuxNextRemoteView
import Testing

/// The system shortcut tap's lifetime: an installed tap stays alive, and keeps
/// working, when its owner lets go, and goes away once `remove()` has invalidated the port. Its
/// callback's refcon is a CallbackRegistry token, so a late callback finds no
/// tap instead of a freed one (RemoteSystemShortcutTapCallbackTests).
@MainActor @Suite struct RemoteSystemShortcutTapLifetimeTests {
    @Test func installedTapStaysAliveUntilRemoved() {
        let port = FakeEventTapPort()
        let surface = RemoteInputSurface()
        weak var weakTap: RemoteSystemShortcutTap?
        do {
            let tap = RemoteSystemShortcutTap(makePort: { _, _, _ in port })
            #expect(tap.install(for: surface))
            weakTap = tap
        }
        let aliveWhileInstalled = weakTap != nil
        #expect(aliveWhileInstalled, "the port can still call back, so the tap must still exist")
        #expect(weakTap?.isInstalled == true)
        #expect(!port.isInvalidated)

        weakTap?.remove()
        #expect(port.isInvalidated)
        let goneAfterRemove = weakTap == nil
        #expect(goneAfterRemove, "after remove() the port cannot call back; the tap must not leak")
    }

    @Test func refusedTapIsNotKeptAlive() {
        let surface = RemoteInputSurface()
        weak var weakTap: RemoteSystemShortcutTap?
        do {
            let tap = RemoteSystemShortcutTap(makePort: { _, _, _ in nil })
            #expect(!tap.install(for: surface))
            #expect(!tap.isInstalled)
            #expect(tap.surface == nil)
            weakTap = tap
        }
        let goneAfterRefusal = weakTap == nil
        #expect(goneAfterRefusal)
    }
}

@MainActor
private final class FakeEventTapPort: RemoteEventTapPort {
    private(set) var isInvalidated = false

    func enable() {}

    func invalidate() {
        isInvalidated = true
    }
}
