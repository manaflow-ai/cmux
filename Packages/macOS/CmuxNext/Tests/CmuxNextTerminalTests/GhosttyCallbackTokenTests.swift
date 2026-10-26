import AppKit
import CmuxNextCompat
@testable import CmuxNextTerminal
import GhosttyNextKit
import Testing

/// p10-stability-082: libghostty's runtime callbacks (`wakeup_cb`, `action_cb`, ...) get the runtime context's
/// ``CallbackRegistry`` token as their userdata, never the context's address, so a callback whose context is
/// gone, or whose token is another owner's, resolves to nothing instead of reading freed memory (Chromium's
/// MiraclePtr property, applied to C callback contexts). Run under `--sanitize=address` too.
@MainActor @Suite(.serialized)
struct GhosttyCallbackTokenTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func theStartedRuntimesUserdataResolvesToItsOwnContext() throws {
        let runtime = GhosttyRuntime.startedForTests()
        let app = try #require(runtime.app, "libghostty made no app")
        // SAFETY: the shared runtime's live app; only its userdata's bits are read.
        let context = try #require(unsafe RuntimeCallbackContext.from(ghostty_app_userdata(app)))
        #expect(context.runtime === runtime)
    }

    @Test func anotherOwnersTokenIsNoRuntimeContext() {
        let other = OtherOwner()
        let token = CallbackRegistry.shared.register(other)
        defer { CallbackRegistry.shared.unregister(token) }
        // Before the registry, the wakeup read an atomic at whatever the userdata pointed at.
        // SAFETY: only the token's bits reach the callback.
        #expect(unsafe RuntimeCallbackContext.from(token.context) == nil)
        unsafe ghosttyWakeup(token.context)
        #expect(unsafe RuntimeCallbackContext.from(nil) == nil)
        withExtendedLifetime(other) {}
    }

    @Test func aContextThatIsGoneResolvesToNothingAndItsWakeupIsIgnored() {
        let token = registeredContextThatThenGoes()
        defer { CallbackRegistry.shared.unregister(token) }
        // SAFETY: only the token's bits reach the callbacks.
        #expect(unsafe RuntimeCallbackContext.from(token.context) == nil, "a freed context is never handed back")
        unsafe ghosttyWakeup(token.context)
    }

    @Test func anUnregisteredContextsTokenResolvesToNothing() {
        let context = RuntimeCallbackContext()
        let token = CallbackRegistry.shared.register(context)
        CallbackRegistry.shared.unregister(token)
        // SAFETY: only the token's bits are read.
        #expect(unsafe RuntimeCallbackContext.from(token.context) == nil, "a stale generation finds nothing")
        withExtendedLifetime(context) {}
    }

    /// A context checked to resolve while it lives; its last reference goes when this returns.
    private func registeredContextThatThenGoes() -> CallbackToken {
        let context = RuntimeCallbackContext()
        let token = CallbackRegistry.shared.register(context)
        // SAFETY: only the token's bits are read.
        #expect(unsafe RuntimeCallbackContext.from(token.context) === context)
        return token
    }

    private final class OtherOwner: Sendable {}
}
