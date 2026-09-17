import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileRPC

/// Decode tests for the terminal-output RPC DTOs, asserting they parse the exact
/// wire shapes the Mac side emits today (the same snake_case JSON the legacy
/// `[String: Any]` paths read).
@Suite struct MobileTerminalDTODecodeTests {
    @Test func subscribeResponseDecodesStreamID() throws {
        let data = Data(#"{"stream_id":"ios-terminal-events-abc"}"#.utf8)
        let response = try MobileEventSubscribeResponse.decode(data)
        #expect(response.streamID == "ios-terminal-events-abc")
    }

    @Test func subscribeResponseTreatsMissingStreamIDAsEmpty() throws {
        let response = try MobileEventSubscribeResponse.decode(Data("{}".utf8))
        #expect(response.streamID.isEmpty)
    }

    @Test func hostStatusDecodesRenderGridCapability() throws {
        let data = Data(#"{"capabilities":["terminal.render_grid.v1"],"terminal_fidelity":"render_grid"}"#.utf8)
        let response = try MobileHostStatusResponse.decode(data)
        #expect(response.capabilities == ["terminal.render_grid.v1"])
        #expect(response.terminalFidelity == "render_grid")
    }

    @Test func hostStatusToleratesMissingFields() throws {
        let response = try MobileHostStatusResponse.decode(Data("{}".utf8))
        #expect(response.capabilities.isEmpty)
        #expect(response.terminalFidelity == nil)
        #expect(response.theme == nil)
    }

    /// A theme nested in the host-status payload, serialized with the Mac
    /// producer's `[String: Any]` key shape, round-trips back into the exact
    /// `TerminalTheme` the Mac sent. This pins the producer/consumer wire
    /// contract: the keys the producer writes must match `TerminalTheme`'s
    /// `Codable` keys the consumer decodes.
    @Test func hostStatusDecodesNestedTheme() throws {
        let expected = TerminalTheme(
            background: "#1e1e2e",
            foreground: "#cdd6f4",
            cursor: "#f5e0dc",
            cursorText: "#11111b",
            selectionBackground: "#585b70",
            selectionForeground: "#cdd6f4",
            palette: (0...15).map { String(format: "#%06x", $0 * 0x111111) }
        )
        // Mirror the Mac producer's `[String: Any]` serialization exactly.
        var themeObject: [String: Any] = [
            "background": expected.background,
            "foreground": expected.foreground,
            "cursor": expected.cursor,
            "cursorText": expected.cursorText as Any,
            "selectionBackground": expected.selectionBackground,
            "selectionForeground": expected.selectionForeground,
            "palette": expected.palette,
        ]
        let payload: [String: Any] = [
            "capabilities": ["terminal.render_grid.v1"],
            "terminal_fidelity": "render_grid",
            "theme": themeObject,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let response = try MobileHostStatusResponse.decode(data)
        #expect(response.theme == expected)

        // A theme without a cursorText decodes that field as nil.
        themeObject.removeValue(forKey: "cursorText")
        let dataNoCursorText = try JSONSerialization.data(
            withJSONObject: ["theme": themeObject]
        )
        let responseNoCursorText = try MobileHostStatusResponse.decode(dataNoCursorText)
        #expect(responseNoCursorText.theme?.cursorText == nil)
        #expect(responseNoCursorText.theme?.background == expected.background)
    }

    /// A present-but-malformed `theme` (wrong types / truncated palette) must
    /// not fail the whole host-status decode. The status payload also drives
    /// transport negotiation and Mac-identity adoption, so a throw here would
    /// force raw-bytes transport and skip identity follow-ups over a cosmetic
    /// field. The bad theme decodes to nil; every other field still parses.
    @Test func hostStatusToleratesMalformedTheme() throws {
        let payload: [String: Any] = [
            "capabilities": ["terminal.render_grid.v1"],
            "terminal_fidelity": "render_grid",
            "mac_display_name": "Studio",
            // `palette` should be an array of strings; a number is invalid.
            "theme": ["background": 1234, "palette": "not-an-array"],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let response = try MobileHostStatusResponse.decode(data)
        #expect(response.theme == nil)
        #expect(response.capabilities == ["terminal.render_grid.v1"])
        #expect(response.terminalFidelity == "render_grid")
        #expect(response.macDisplayName == "Studio")
    }

    @Test func inputResponseDecodesTerminalSeq() throws {
        let data = Data(#"{"terminal_seq":4242}"#.utf8)
        let response = try MobileTerminalInputResponse.decode(data)
        #expect(response.terminalSeq == 4242)
    }

    @Test func inputResponseToleratesMissingSeq() throws {
        let response = try MobileTerminalInputResponse.decode(Data("{}".utf8))
        #expect(response.terminalSeq == nil)
    }

    @Test func viewportResponseComputesEffectiveGrid() throws {
        let data = Data(#"{"columns":120,"rows":40}"#.utf8)
        let response = try MobileTerminalViewportResponse.decode(data)
        let grid = try #require(response.effectiveGrid)
        #expect(grid.columns == 120)
        #expect(grid.rows == 40)
    }

    @Test func viewportResponseRejectsNonPositiveGrid() throws {
        let response = try MobileTerminalViewportResponse.decode(Data(#"{"columns":0,"rows":40}"#.utf8))
        #expect(response.effectiveGrid == nil)
    }

    @Test func replayResponseDecodesRawTailAndSeq() throws {
        let base64 = Data("hello".utf8).base64EncodedString()
        let json = "{\"data_b64\":\"\(base64)\",\"seq\":99}"
        let response = try MobileTerminalReplayResponse.decode(Data(json.utf8))
        #expect(response.dataBase64 == base64)
        #expect(response.sequence == 99)
        #expect(response.renderGrid == nil)
    }

    @Test func replayResponseDecodesNestedRenderGrid() throws {
        let json = """
        {
          "render_grid": {
            "format": "cmux.render-grid.v1",
            "surface_id": "surface-1",
            "state_seq": 7,
            "columns": 2,
            "rows": 1,
            "row_spans": []
          },
          "seq": 7
        }
        """
        let response = try MobileTerminalReplayResponse.decode(Data(json.utf8))
        let frame = try #require(response.renderGrid)
        #expect(frame.surfaceID == "surface-1")
        #expect(frame.stateSeq == 7)
    }

    @Test func bytesEventDecodesBase64AndSeq() throws {
        let base64 = Data([0x1B, 0x5B, 0x32, 0x4A]).base64EncodedString()
        let json = "{\"surface_id\":\"surface-9\",\"data_b64\":\"\(base64)\",\"seq\":1024}"
        let event = try #require(MobileTerminalBytesEvent.decode(Data(json.utf8)))
        #expect(event.surfaceID == "surface-9")
        #expect(event.bytes == Data([0x1B, 0x5B, 0x32, 0x4A]))
        #expect(event.sequence == 1024)
    }

    @Test func bytesEventReturnsNilOnMissingFields() {
        #expect(MobileTerminalBytesEvent.decode(Data(#"{"surface_id":"x"}"#.utf8)) == nil)
    }

    @Test func renderGridEventDecodesWrappedFrame() throws {
        let json = """
        {
          "render_grid": {
            "format": "cmux.render-grid.v1",
            "surface_id": "surface-2",
            "state_seq": 3,
            "columns": 4,
            "rows": 1,
            "row_spans": []
          }
        }
        """
        let event = try MobileTerminalRenderGridEvent.decode(Data(json.utf8))
        let frame = try #require(event.frame)
        #expect(frame.surfaceID == "surface-2")
    }

    @Test func renderGridEventHasNilFrameWhenUnwrapped() throws {
        let json = """
        {
          "format": "cmux.render-grid.v1",
          "surface_id": "surface-3",
          "state_seq": 5,
          "columns": 4,
          "rows": 1,
          "row_spans": []
        }
        """
        let event = try MobileTerminalRenderGridEvent.decode(Data(json.utf8))
        #expect(event.frame == nil)
    }
}
