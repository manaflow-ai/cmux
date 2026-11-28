import Testing

@testable import CMUXMobileCore

@Test func renderGridVisualSnapshotCanonicalizesDefaultGapsAndSpanPartitions() throws {
    let styles = [
        MobileTerminalRenderGridFrame.Style(
            id: 0,
            foreground: "#FFFFFF",
            background: "#000000"
        ),
        .init(id: 1, foreground: "#00FF00", background: "#000000")
    ]
    let compact = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 1,
        columns: 8,
        rows: 1,
        styles: styles,
        rowSpans: [
            .init(row: 0, column: 0, styleID: 1, text: "left"),
            .init(row: 0, column: 7, styleID: 1, text: "x")
        ]
    )
    let explicit = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 2,
        columns: 8,
        rows: 1,
        styles: styles,
        rowSpans: [
            .init(row: 0, column: 0, styleID: 1, text: "le"),
            .init(row: 0, column: 2, styleID: 1, text: "ft"),
            .init(row: 0, column: 4, styleID: 0, text: "   "),
            .init(row: 0, column: 7, styleID: 1, text: "x")
        ]
    )

    #expect(
        MobileTerminalRenderGridVisualSnapshot(fullFrame: compact)
            == MobileTerminalRenderGridVisualSnapshot(fullFrame: explicit)
    )
}

@Test func renderGridVisualSnapshotPreservesStyledBlankCells() throws {
    let styles = [
        MobileTerminalRenderGridFrame.Style(
            id: 0,
            foreground: "#FFFFFF",
            background: "#000000"
        ),
        .init(id: 1, foreground: "#FFFFFF", background: "#585858")
    ]
    let omitted = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 1,
        columns: 4,
        rows: 1,
        styles: styles,
        rowSpans: []
    )
    let styledBlank = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 2,
        columns: 4,
        rows: 1,
        styles: styles,
        rowSpans: [.init(row: 0, column: 1, styleID: 1, text: "  ")]
    )

    #expect(
        MobileTerminalRenderGridVisualSnapshot(fullFrame: omitted)
            != MobileTerminalRenderGridVisualSnapshot(fullFrame: styledBlank)
    )
}

@Test func renderGridVisualSnapshotIgnoresUndecoratedBlankForeground() throws {
    let expected = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 1,
        columns: 4,
        rows: 1,
        styles: [
            .init(id: 0, foreground: "#FFFFFF", background: "#000000")
        ],
        rowSpans: []
    )
    let configuredForeground = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 2,
        columns: 4,
        rows: 1,
        styles: [
            .init(id: 0, foreground: "#FFFFFF", background: "#000000"),
            .init(id: 1, foreground: "#FDFFF1", background: "#000000")
        ],
        rowSpans: [.init(row: 0, column: 0, styleID: 1, text: "    ")]
    )

    #expect(
        MobileTerminalRenderGridVisualSnapshot(fullFrame: expected)
            == MobileTerminalRenderGridVisualSnapshot(fullFrame: configuredForeground)
    )
}

@Test func renderGridVisualSnapshotPreservesVisibleForegroundDifferences() throws {
    func snapshot(
        text: String,
        foreground: String,
        underline: Bool = false,
        inverse: Bool = false
    ) throws -> MobileTerminalRenderGridVisualSnapshot {
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "terminal-a",
            stateSeq: 1,
            columns: 4,
            rows: 1,
            styles: [
                .init(id: 0, foreground: "#FFFFFF", background: "#000000"),
                .init(
                    id: 1,
                    foreground: foreground,
                    background: "#000000",
                    underline: underline,
                    inverse: inverse
                )
            ],
            rowSpans: [.init(row: 0, column: 0, styleID: 1, text: text)]
        )
        return try #require(MobileTerminalRenderGridVisualSnapshot(fullFrame: frame))
    }

    #expect(try snapshot(text: "x", foreground: "#FFFFFF")
        != snapshot(text: "x", foreground: "#FDFFF1"))
    #expect(try snapshot(text: " ", foreground: "#FFFFFF", underline: true)
        != snapshot(text: " ", foreground: "#FDFFF1", underline: true))
    #expect(try snapshot(text: " ", foreground: "#FFFFFF", inverse: true)
        != snapshot(text: " ", foreground: "#FDFFF1", inverse: true))
}
