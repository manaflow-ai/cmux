import CoreGraphics
@testable import CmuxNextRemoteView
import Testing

/// The system shortcut tap's lifetime (p10-stability-066): its event tap calls back with the tap
/// instance unretained, so an installed tap must stay alive when its owner lets go, and go away
/// once `remove()` has invalidated the port. Before `installedSelf`, the owner's last release
/// freed the instance while the port could still call back with it (a use after free).
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
