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

@Test func semanticDefaultStyleSurvivesColdReplayForLaterThemeChanges() throws {
    let json = Data(
        """
        {
          "format": "cmux.render-grid.v1",
          "surface_id": "semantic-theme",
          "state_seq": 1,
          "columns": 4,
          "rows": 1,
          "full": true,
          "styles": [{
            "id": 0,
            "foreground": "#FDFFF1",
            "background": "#272822",
            "foreground_source": "default",
            "background_source": "default"
          }],
          "row_spans": [{
            "row": 0,
            "column": 0,
            "style_id": 0,
            "cell_width": 4,
            "text": "test"
          }]
        }
        """.utf8
    )

    let frame = try MobileTerminalRenderGridFrame.decode(json)
    let replay = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))

    #expect(replay.contains("\u{1B}[0;39;49m"))
    #expect(!replay.contains("48;2;39;40;34"))
}

@Test func boldStyleRetainsSemanticForegroundForLaterThemeChanges() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "bold-color",
        stateSeq: 1,
        columns: 4,
        rows: 1,
        styles: [
            .init(
                id: 0,
                foreground: "#4e2a84",
                foregroundSource: .defaultColor,
                bold: true
            ),
        ],
        rowSpans: [
            .init(row: 0, column: 0, styleID: 0, text: "bold", cellWidth: 4),
        ]
    )

    let replay = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))

    #expect(replay.contains("\u{1B}[0;1;39m"))
    #expect(!replay.contains("\u{1B}[0;1;38;2;78;42;132m"))
}
