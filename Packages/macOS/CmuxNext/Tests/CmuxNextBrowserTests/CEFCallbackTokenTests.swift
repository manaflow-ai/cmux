import AppKit
import CmuxNextCompat
@testable import CmuxNextBrowser
import Testing

/// p10-stability-082: the shim's callbacks get the runtime's ``CallbackRegistry`` token as their context, never
/// the runtime's address, so a context that is no live runtime's token finds nothing instead of being read as
/// one (Chromium's MiraclePtr property, applied to C callback contexts). Run under `--sanitize=address` too.
@MainActor @Suite(.serialized)
struct CEFCallbackTokenTests {
    @Test func aNullContextFindsNoRuntime() {
        #expect(CEFRuntime.from(0) == nil)
        #expect(CEFRuntime.pumpGate(at: 0) == nil)
    }

    @Test func anotherOwnersTokenFindsNoRuntime() {
        let other = OtherOwner()
        let token = CallbackRegistry.shared.register(other)
        defer { CallbackRegistry.shared.unregister(token) }
        let bits = Self.bits(of: token)
        // Before the registry, these read a CEFRuntime at the context's address.
        #expect(CEFRuntime.from(bits) == nil)
        #expect(CEFRuntime.pumpGate(at: bits) == nil, "the Chromium-thread path resolves the same way")
        withExtendedLifetime(other) {}
    }

    @Test func aScheduleRequestWithAStaleContextReachesNoPump() {
        let other = OtherOwner()
        let token = CallbackRegistry.shared.register(other)
        CallbackRegistry.shared.unregister(token)
        // On the main thread the request is delivered in the call: it resolves the context, finds nothing, returns.
        // SAFETY: only the token's bits reach the callback.
        unsafe cefScheduleCallback(token.context, 0)
        #expect(CEFRuntime.from(Self.bits(of: token)) == nil)
        withExtendedLifetime(other) {}
    }

    @Test func aParentViewIsTheViewsOwnAddress() {
        let view = NSView()
        // SAFETY: compares the two addresses only.
        #expect(unsafe CEFParentView(view: view).pointer == Unmanaged.passUnretained(view).toOpaque())
    }

    private static func bits(of token: CallbackToken) -> UInt {
        // SAFETY: only the context's bits are read.
        unsafe UInt(bitPattern: token.context)
    }

    private final class OtherOwner: Sendable {}
}
