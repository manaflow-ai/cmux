import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

// Behavior coverage for inheriting the Mac's resolved Ghostty theme onto the
// phone's chrome. The terminal surface itself inherits the palette + default
// colors through the replayed OSC sequences in the byte stream; the store also
// records the Mac's default background per surface so the surrounding chrome
// (the input-accessory bar) can match it instead of a hardcoded Monokai.

// Serialized: each connected store binds the same fixed loopback port (see
// `makeTicket`), so two of these running concurrently would collide on it.
@Suite(.serialized)
@MainActor
struct MobileShellInheritedThemeTests {

/// A full render-grid frame carrying the Mac's default background is recorded
/// for the surface, so the chrome can read it back via
/// ``MobileShellComposite/inheritedTerminalBackground(surfaceID:)``.
@Test func inheritedTerminalBackgroundRecordedFromFullFrame() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay)

    #expect(
        store.inheritedTerminalBackground(surfaceID: "live-terminal") == nil,
        "no frame seen yet, so the chrome must fall back to its built-in default"
    )

    let palette = (0..<16).map { String(format: "#0000%02X", $0 * 16) }
    let event = try themedRenderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 5,
        background: "#123456",
        palette: palette
    )
    let transport = try #require(box.get())
    await transport.deliver(event)

    let recorded = try await pollUntil {
        store.inheritedTerminalBackground(surfaceID: "live-terminal") == "#123456"
    }
    #expect(
        recorded,
        "a full frame's terminal background must be recorded so the phone's chrome inherits the Mac's theme background, not a hardcoded Monokai"
    )

    collector.unmount()
}

/// A delta frame omits the background, so the last inherited background survives
/// across deltas rather than reverting to the fallback.
@Test func inheritedTerminalBackgroundSurvivesDeltaFrames() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    _ = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }

    let transport = try #require(box.get())
    let palette = (0..<16).map { _ in "#abcdef" }
    let full = try themedRenderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 5,
        background: "#0A0B0C",
        palette: palette
    )
    await transport.deliver(full)
    _ = try await pollUntil {
        store.inheritedTerminalBackground(surfaceID: "live-terminal") == "#0A0B0C"
    }

    // A subsequent delta (no background) must not clear the inherited value.
    // A delta legitimately omits the background, so the established value must
    // persist (unlike a full frame's nil background, which clears it). Wait until
    // the delta's output has been delivered (proving it passed through the same
    // `deliverTerminalRenderGrid` funnel that records backgrounds), then assert
    // the inherited background is unchanged.
    let delta = try deltaRenderGridEventFrame(surfaceID: "live-terminal", seq: 6, text: "more")
    await transport.deliver(delta)
    let sawDelta = try await pollUntil {
        collector.lines.contains { $0.contains("more") }
    }
    #expect(sawDelta, "the delta frame must reach the surface output")

    #expect(
        store.inheritedTerminalBackground(surfaceID: "live-terminal") == "#0A0B0C",
        "a delta carries no background, so the last full-frame background must persist"
    )

    collector.unmount()
}

/// A full snapshot with no background is authoritative: the Mac's configured
/// default background was removed or no longer resolves, so the previously
/// inherited chrome background must be cleared (revert to the fallback), not
/// kept stale.
@Test func inheritedTerminalBackgroundClearedByBackgroundlessFullFrame() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    _ = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }

    let transport = try #require(box.get())
    let palette = (0..<16).map { _ in "#abcdef" }
    let themed = try themedRenderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 5,
        background: "#0A0B0C",
        palette: palette
    )
    await transport.deliver(themed)
    _ = try await pollUntil {
        store.inheritedTerminalBackground(surfaceID: "live-terminal") == "#0A0B0C"
    }

    // A full frame with no background (theme background removed/unresolved on the
    // Mac). `renderGridEventFrame` builds a full snapshot with no terminal colors.
    let backgroundless = try renderGridEventFrame(surfaceID: "live-terminal", seq: 6, text: "plain")
    await transport.deliver(backgroundless)
    let cleared = try await pollUntil {
        store.inheritedTerminalBackground(surfaceID: "live-terminal") == nil
    }
    #expect(
        cleared,
        "a full snapshot with no background must clear the inherited chrome color so it does not stay stale"
    )

    collector.unmount()
}

}
