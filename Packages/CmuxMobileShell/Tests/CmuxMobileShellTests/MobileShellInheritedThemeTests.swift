import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

// Behavior coverage for inheriting the Mac's resolved Ghostty theme onto the
// phone's chrome. The terminal surface itself inherits the palette + default
// colors through the replayed OSC sequences in the byte stream; the store also
// records the Mac's default background per surface so the surrounding chrome
// (the input-accessory bar) can match it instead of a hardcoded Monokai.
//
// These drive the recording path directly through a preview store + a registered
// output sink (no network/loopback), so they run anywhere `swift test` runs.
@MainActor
struct MobileShellInheritedThemeTests {
    /// Mount an output sink for `surfaceID` on a connectionless preview store and
    /// return both. Keep the returned stream's iterator alive for the test's
    /// duration so the sink stays registered.
    private func makeStoreWithSink(
        surfaceID: String
    ) -> (store: MobileShellComposite, stream: AsyncStream<MobileTerminalOutputChunk>) {
        let store = MobileShellComposite.preview()
        let stream = store.terminalOutputStream(surfaceID: surfaceID)
        return (store, stream)
    }

    private func fullFrame(
        surfaceID: String,
        seq: UInt64,
        background: String?,
        palette: [String]? = nil
    ) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: surfaceID,
            stateSeq: seq,
            columns: 16,
            rows: 4,
            rowSpans: [.init(row: 0, column: 0, text: "x")],
            terminalBackground: background,
            terminalPalette: palette
        )
    }

    private func deltaFrame(surfaceID: String, seq: UInt64) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: surfaceID,
            stateSeq: seq,
            columns: 16,
            rows: 4,
            full: false,
            rowSpans: [.init(row: 0, column: 0, text: "y")]
        )
    }

    /// A full frame carrying the Mac's default background is recorded for the
    /// surface, so the chrome can read it back.
    @Test func recordsBackgroundFromFullFrame() throws {
        let surfaceID = "terminal-a"
        let (store, stream) = makeStoreWithSink(surfaceID: surfaceID)
        defer { withExtendedLifetime(stream) {} }

        #expect(store.inheritedTerminalBackground(surfaceID: surfaceID) == nil)

        let palette = (0..<16).map { String(format: "#0000%02X", $0 * 16) }
        store.deliverTerminalRenderGrid(
            try fullFrame(surfaceID: surfaceID, seq: 5, background: "#123456", palette: palette),
            surfaceID: surfaceID
        )
        #expect(store.inheritedTerminalBackground(surfaceID: surfaceID) == "#123456")
    }

    /// A delta frame omits the background, so the last inherited value persists
    /// rather than reverting to the fallback.
    @Test func backgroundSurvivesDeltaFrame() throws {
        let surfaceID = "terminal-a"
        let (store, stream) = makeStoreWithSink(surfaceID: surfaceID)
        defer { withExtendedLifetime(stream) {} }

        store.deliverTerminalRenderGrid(
            try fullFrame(surfaceID: surfaceID, seq: 5, background: "#0A0B0C"),
            surfaceID: surfaceID
        )
        store.deliverTerminalRenderGrid(
            try deltaFrame(surfaceID: surfaceID, seq: 6),
            surfaceID: surfaceID
        )
        #expect(
            store.inheritedTerminalBackground(surfaceID: surfaceID) == "#0A0B0C",
            "a delta carries no background, so the last full-frame background must persist"
        )
    }

    /// A full snapshot with no background is authoritative: the Mac's default
    /// background was removed/unresolved, so the inherited chrome color is cleared.
    @Test func backgroundlessFullFrameClearsInheritedColor() throws {
        let surfaceID = "terminal-a"
        let (store, stream) = makeStoreWithSink(surfaceID: surfaceID)
        defer { withExtendedLifetime(stream) {} }

        store.deliverTerminalRenderGrid(
            try fullFrame(surfaceID: surfaceID, seq: 5, background: "#0A0B0C"),
            surfaceID: surfaceID
        )
        #expect(store.inheritedTerminalBackground(surfaceID: surfaceID) == "#0A0B0C")

        store.deliverTerminalRenderGrid(
            try fullFrame(surfaceID: surfaceID, seq: 6, background: nil),
            surfaceID: surfaceID
        )
        #expect(
            store.inheritedTerminalBackground(surfaceID: surfaceID) == nil,
            "a full snapshot with no background must clear the inherited chrome color"
        )
    }

    /// A frame for a surface with no registered sink is dropped by delivery, so it
    /// must not record (or repopulate) the inherited background.
    @Test func droppedFrameDoesNotRecordBackground() throws {
        let store = MobileShellComposite.preview()
        // No sink registered for this surface.
        store.deliverTerminalRenderGrid(
            try fullFrame(surfaceID: "terminal-ghost", seq: 1, background: "#FFFFFF"),
            surfaceID: "terminal-ghost"
        )
        #expect(
            store.inheritedTerminalBackground(surfaceID: "terminal-ghost") == nil,
            "a frame with no output sink is not delivered, so it must not record a background"
        )
    }
}
