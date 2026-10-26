import CoreGraphics
@testable import CmuxNextRemoteView
import Testing

/// The system shortcut tap's event tap callback takes a CallbackRegistry token as its refcon
/// (p10-stability-081): a callback that fires after `remove()` (the tap's entry is gone) lets
/// the event through unchanged and is counted, where an unretained instance pointer would have
/// been a use after free.
@MainActor @Suite struct RemoteSystemShortcutTapCallbackTests {
    @Test func callbackAfterRemoveLetsTheEventThroughAndIsCounted() throws {
        let port = CallbackTestEventTapPort()
        let surface = RemoteInputSurface()
        var installed: (callback: CGEventTapCallBack, refcon: UnsafeMutableRawPointer?)?
        let tap = RemoteSystemShortcutTap(makePort: { _, callback, refcon in
            unsafe installed = (callback, refcon)
            return port
        })
        #expect(tap.install(for: surface))
        let (callback, refcon) = try #require(unsafe installed)
        tap.remove()
        #expect(port.isInvalidated)

        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        let proxy = try #require(unsafe OpaquePointer(bitPattern: 1))
        let before = remoteSystemShortcutTapCallbacks.ignoredCount
        let passed = unsafe callback(proxy, .keyDown, event, refcon)
        #expect(unsafe passed?.takeUnretainedValue() === event, "the event passes on unchanged")
        #expect(remoteSystemShortcutTapCallbacks.ignoredCount == before + 1)
    }
}

@MainActor
private final class CallbackTestEventTapPort: RemoteEventTapPort {
    private(set) var isInvalidated = false

    func enable() {}

    func invalidate() {
        isInvalidated = true
    }
}
