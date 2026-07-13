import Foundation
import Testing
@testable import CMUXMobileCore

@Test func fullReplayRestoresEffectivePaletteOverridesAgainstRawConfig() throws {
    var config = TerminalTheme.monokai
    config.palette = (0..<TerminalTheme.extendedPaletteCount).map {
        String(format: "#%06x", $0)
    }
    var effective = config
    effective.palette[4] = "#123456"
    effective.palette[200] = "#abcdef"
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-palette",
        stateSeq: 1,
        columns: 2,
        rows: 1,
        rowSpans: [],
        terminalTheme: effective,
        terminalConfigTheme: config
    )

    let replay = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))

    #expect(replay.contains("\u{1B}]104\u{1B}\\"))
    #expect(replay.contains("\u{1B}]4;4;rgb:12/34/56\u{1B}\\"))
    #expect(replay.contains("\u{1B}]4;200;rgb:ab/cd/ef\u{1B}\\"))
    #expect(!replay.contains("\u{1B}]4;5;"))
}

@Test func fullReplayWithoutThemePreservesUnrepresentedPaletteOverrides() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-legacy",
        stateSeq: 1,
        columns: 2,
        rows: 1,
        rowSpans: []
    )

    let replay = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))

    #expect(!replay.contains("\u{1B}]104"))
    #expect(!replay.contains("\u{1B}]4;0;"))
}

@Test func fullReplayWithBasePaletteResetsOnlyRepresentedIndices() throws {
    var effective = TerminalTheme.monokai
    effective.palette[4] = "#123456"
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-base-palette",
        stateSeq: 1,
        columns: 2,
        rows: 1,
        rowSpans: [],
        terminalTheme: effective,
        terminalConfigTheme: .monokai
    )

    let replay = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))

    #expect(replay.contains("\u{1B}]104;0;1;2;3;4;5;6;7;8;9;10;11;12;13;14;15\u{1B}\\"))
    #expect(!replay.contains("\u{1B}]104\u{1B}\\"))
    #expect(replay.contains("\u{1B}]4;4;rgb:12/34/56\u{1B}\\"))
    #expect(!replay.contains("\u{1B}]104;16"))
}
