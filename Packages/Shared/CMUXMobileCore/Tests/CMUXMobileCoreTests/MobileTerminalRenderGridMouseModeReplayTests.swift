import Foundation
import Testing
@testable import CMUXMobileCore

/// Ghostty keeps one mouse event mode and one mouse format, and each DEC mode
/// in a family overwrites it: `?1006h` selects SGR and `?1015l` resets the
/// format to X10 even though SGR is still recorded on. The host's render grid
/// lists every mode, on or off, in mode-number order, so the replay must not
/// let a later "off" in a family undo an earlier "on".
private struct GhosttyMouseState {
    var event = "none"
    var format = "x10"

    init(applying vt: String) {
        let pattern = try! NSRegularExpression(pattern: "\u{1B}\\[\\?([0-9]+)([hl])")
        let range = NSRange(vt.startIndex..., in: vt)
        for match in pattern.matches(in: vt, range: range) {
            guard let codeRange = Range(match.range(at: 1), in: vt),
                  let flagRange = Range(match.range(at: 2), in: vt),
                  let code = Int(vt[codeRange]) else { continue }
            let on = vt[flagRange] == "h"
            switch code {
            case 9: event = on ? "x10" : "none"
            case 1000: event = on ? "normal" : "none"
            case 1002: event = on ? "button" : "none"
            case 1003: event = on ? "any" : "none"
            case 1005: format = on ? "utf8" : "x10"
            case 1006: format = on ? "sgr" : "x10"
            case 1015: format = on ? "urxvt" : "x10"
            case 1016: format = on ? "sgr_pixels" : "x10"
            default: break
            }
        }
    }
}

private func hostModeList(on enabled: Set<Int>) -> [MobileTerminalRenderGridFrame.ModeSetting] {
    [9, 1000, 1002, 1003, 1004, 1005, 1006, 1007, 1015, 1016, 2004].map {
        .init(code: $0, ansi: false, on: enabled.contains($0) || $0 == 1007)
    }
}

private func replayedMouseState(on enabled: Set<Int>) throws -> GhosttyMouseState {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 1,
        columns: 8,
        rows: 1,
        cursor: .init(row: 0, column: 0),
        rowSpans: [.init(row: 0, column: 0, text: "tui")],
        modes: hostModeList(on: enabled)
    )
    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    return GhosttyMouseState(applying: vt)
}

@Test func renderGridFullSnapshotKeepsSGRMouseFormat() throws {
    // Claude Code's fullscreen TUI: any-motion tracking with SGR reports.
    let state = try replayedMouseState(on: [1003, 1006])
    #expect(state.event == "any")
    #expect(state.format == "sgr")
}

@Test func renderGridFullSnapshotKeepsButtonMouseTracking() throws {
    let state = try replayedMouseState(on: [1002, 1006])
    #expect(state.event == "button")
    #expect(state.format == "sgr")
}

@Test func renderGridFullSnapshotKeepsUTF8MouseFormat() throws {
    let state = try replayedMouseState(on: [1000, 1005])
    #expect(state.event == "normal")
    #expect(state.format == "utf8")
}

@Test func renderGridFullSnapshotLeavesMouseOffWhenHostHasItOff() throws {
    let state = try replayedMouseState(on: [])
    #expect(state.event == "none")
    #expect(state.format == "x10")
}
