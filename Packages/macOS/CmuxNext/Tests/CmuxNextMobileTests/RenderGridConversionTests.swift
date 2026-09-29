import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxNextMobile

/// Daemon render-mode snapshots, captured from a real cmux-tui, converted to
/// the shipped iOS grid and read back through the phone's own decoder and
/// visual model (CMUXMobileCore is the code the iOS app links).
struct RenderGridConversionTests {
    private func phoneFrame(fixture: String, stateSeq: UInt64 = 7) throws -> MobileTerminalRenderGridFrame {
        let event = try JSONDecoder().decode(DaemonRenderFrame.self,
                                             from: FixtureLoader.data(fixture, key: "render_state"))
        var state = DaemonRenderGridState(surfaceID: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", renderEpoch: "epoch-1")
        let applied = state.apply(event)
        #expect(applied)
        let wire = try JSONEncoder().encode(try state.frame(stateSeq: stateSeq))
        return try MobileTerminalRenderGridFrame.decode(wire)
    }

    private func rowText(_ snapshot: MobileTerminalRenderGridVisualSnapshot, _ row: Int) -> String {
        var cells = Array(repeating: " ", count: snapshot.columns)
        for span in snapshot.rows[row] {
            cells[span.column] = span.text
            for pad in 1..<max(1, span.cellWidth) where span.column + pad < cells.count { cells[span.column + pad] = "" }
        }
        return cells.joined().replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    @Test func styledPrimaryScreenRoundTripsThroughPhoneDecoder() throws {
        let frame = try phoneFrame(fixture: "render-styled-primary")
        #expect(frame.format == "cmux.render-grid.v1")
        #expect(frame.full)
        #expect(frame.columns == 40 && frame.rows == 6)
        #expect(frame.stateSeq == 7 && frame.renderEpoch == "epoch-1" && frame.renderRevision == 1)
        #expect(frame.terminalBackground == "#272822" && frame.terminalForeground == "#fdfff1")
        #expect(frame.cursor == .init(row: 2, column: 2, visible: true, style: .bar, blinking: true))

        let snapshot = try #require(MobileTerminalRenderGridVisualSnapshot(fullFrame: frame))
        #expect(rowText(snapshot, 0) == "red bold plain rgb")
        #expect(rowText(snapshot, 1) == "under 日本 inv")
        #expect(rowText(snapshot, 2) == "$")

        let red = try #require(snapshot.rows[0].first { $0.text == "red bold" })
        #expect(red.style.bold && red.style.foreground?.lowercased() == "#f92672")
        let rgb = try #require(snapshot.rows[0].first { $0.text == "rgb" })
        #expect(rgb.column == 15 && rgb.style.foreground?.lowercased() == "#0ac81e")
        let wide = try #require(snapshot.rows[1].first { $0.text.contains("日本") })
        #expect(wide.column == 5 && wide.cellWidth == 6)
        let inverse = try #require(snapshot.rows[1].first { $0.text == "inv" })
        #expect(inverse.column == 11 && inverse.style.inverse)
        let under = try #require(snapshot.rows[1].first { $0.text == "under" })
        #expect(under.style.underline)
    }

    @Test func alternateScreenTUIKeepsBackgroundFillsAndHiddenCursor() throws {
        let frame = try phoneFrame(fixture: "render-alternate-screen")
        let snapshot = try #require(MobileTerminalRenderGridVisualSnapshot(fullFrame: frame))
        let bar = try #require(snapshot.rows[0].first { $0.text == " top bar " })
        #expect(bar.column == 0 && bar.style.background?.lowercased() == "#fd971f")
        let italic = try #require(snapshot.rows[2].first { $0.text == "italic" })
        #expect(italic.column == 4 && italic.style.italic)
        #expect(frame.cursor?.visible == false)
        // Documented gap: render mode does not report the alternate screen.
        #expect(frame.activeScreen == .primary)
    }

    @Test func phoneReplaySynthesizesVisibleText() throws {
        let frame = try phoneFrame(fixture: "render-styled-primary")
        let replay = String(decoding: frame.vtReplacementBytes(), as: UTF8.self)
        for text in ["red bold", " plain ", "rgb", "under", "\u{1B}[7G日\u{1B}[9G本", "[12G\u{1B}[0;7minv", "$"] {
            #expect(replay.contains(text), "\(text)")
        }
        #expect(replay.contains("38;2;249;38;114") || replay.lowercased().contains("f92672"))
    }

    @Test func deltaRowsPatchTheViewport() throws {
        let initial = try JSONDecoder().decode(DaemonRenderFrame.self,
                                               from: FixtureLoader.data("render-styled-primary", key: "render_state"))
        var state = DaemonRenderGridState(surfaceID: "S", renderEpoch: "e")
        state.apply(initial)
        let delta = #"{"event":"render-delta","surface":2,"full":false,"cursor":{"x":5,"y":2,"style":"block","blink":false,"visible":true,"color":null},"rows":[{"row":2,"runs":[{"text":"$ ls ","fg":null,"bg":null,"attrs":0},{"text":"                                   ","fg":null,"bg":null,"attrs":0}]}]}"#
        let patched = state.apply(try JSONDecoder().decode(DaemonRenderFrame.self, from: Data(delta.utf8)))
        #expect(patched)
        let frame = try MobileTerminalRenderGridFrame.decode(JSONEncoder().encode(state.frame(stateSeq: 8)))
        let snapshot = try #require(MobileTerminalRenderGridVisualSnapshot(fullFrame: frame))
        #expect(rowText(snapshot, 2) == "$ ls")
        #expect(rowText(snapshot, 0) == "red bold plain rgb")
        #expect(frame.renderRevision == 2 && frame.cursor?.column == 5 && frame.cursor?.style == .block)
    }

    @Test func deltaBeforeSnapshotIsRejected() throws {
        var state = DaemonRenderGridState(surfaceID: "S")
        let delta = #"{"event":"render-delta","full":false,"cursor":{"x":0,"y":0,"style":"block","blink":false,"visible":true},"rows":[]}"#
        let applied = state.apply(try JSONDecoder().decode(DaemonRenderFrame.self, from: Data(delta.utf8)))
        #expect(!applied)
        #expect(!state.hasViewport)
    }
}
