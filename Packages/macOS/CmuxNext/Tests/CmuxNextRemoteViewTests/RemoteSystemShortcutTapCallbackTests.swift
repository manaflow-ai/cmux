import CoreGraphics
@testable import CmuxNextRemoteView
import Testing

/// The system shortcut tap's event tap callback takes a CallbackRegistry token as its refcon:
/// a callback that fires after `remove()` (the tap's entry is gone) lets
/// the event through unchanged and is counted, where an unretained instance pointer would have
/// been a use after free.
@MainActor @Suite struct RemoteSystemShortcutTapCallbackTests {
    @Test func callbackAfterRemoveLetsTheEventThroughAndIsCounted() throws {
        let port = CallbackTestEventTapPort()
        let surface = RemoteInputSurface()
        var installedCallback: CGEventTapCallBack?
        var installedRefcon: UnsafeMutableRawPointer?
        let tap = RemoteSystemShortcutTap(makePort: { _, callback, refcon in
            installedCallback = callback
            unsafe installedRefcon = refcon
            return port
        })
        #expect(tap.install(for: surface))
        let callback = try #require(installedCallback)
        let refcon = unsafe installedRefcon
        #expect(refcon != nil, "the refcon is a token, never nil")
        tap.remove()
        #expect(port.isInvalidated)

        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        let proxyPointer = unsafe OpaquePointer(bitPattern: 1)
        let proxy = try #require(proxyPointer)
        let before = remoteSystemShortcutTapCallbacks.ignoredCount
        let passed = unsafe callback(proxy, .keyDown, event, refcon)
        let passedEvent = unsafe passed?.takeUnretainedValue()
        #expect(passedEvent === event, "the event passes on unchanged")
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
