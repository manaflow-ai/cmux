import Testing
@testable import CMUXMobileCore

@Test func viewportProjectionWrapsAndKeepsNewestRows() throws {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "surface-a",
        stateSeq: 1,
        columns: 10,
        rows: 3,
        text: "abcdefghij\nsecond\nlatest"
    )

    let projected = frame.projectedViewport(columns: 4, rows: 3)

    #expect(projected.columns == 4)
    #expect(projected.rows == 3)
    #expect(projected.full)
    #expect(projected.plainRows() == ["nd", "late", "st"])
}

@Test func viewportProjectionPreservesRevisionsAndStyles() throws {
    let style = MobileTerminalRenderGridFrame.Style(
        id: 1,
        foreground: "#ff0000",
        background: "#000000",
        bold: true
    )
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "surface-a",
        stateSeq: 3,
        renderEpoch: "epoch-1",
        renderRevision: 7,
        emissionRevision: 11,
        columns: 8,
        rows: 2,
        styles: [.default, style],
        rowSpans: [.init(row: 0, column: 0, styleID: 1, text: "hello")]
    )

    let projected = frame.projectedViewport(columns: 5, rows: 2)

    #expect(projected.renderEpoch == "epoch-1")
    #expect(projected.renderRevision == 7)
    #expect(projected.emissionRevision == 11)
    #expect(projected.rowSpans.first?.styleID == 1)
}

@Test func textProjectionKeepsAllRowsWhenRequested() {
    let text = "0123456789\nabcdefghij"

    #expect(text.projectedTerminalText(columns: 4, rows: 2, keepAllRows: false) == "efgh\nij")
    #expect(text.projectedTerminalText(columns: 4, rows: 2, keepAllRows: true) == "0123\n4567\n89\nabcd\nefgh\nij")
}
