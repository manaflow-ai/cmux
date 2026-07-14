import Foundation
import Testing
@testable import CMUXMobileCore

@Test func semanticReplayKeepsOriginModeRowChangesScrollbackPreserving() throws {
    let previous = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 1,
        columns: 16,
        rows: 2,
        cursor: .init(row: 0, column: 4),
        rowSpans: [.init(row: 0, column: 0, text: "before")],
        modes: [.init(code: 6, on: true)],
        scrollbackRows: 1,
        scrollbackSpans: [.init(row: 0, column: 0, text: "history")]
    )
    let next = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 2,
        columns: 16,
        rows: 2,
        cursor: .init(row: 1, column: 3),
        rowSpans: [.init(row: 0, column: 0, text: "after")],
        modes: [.init(code: 6, on: true)],
        scrollbackRows: 1,
        scrollbackSpans: [.init(row: 0, column: 0, text: "history")]
    )

    let bytes = next.semanticReplayBytes(comparedTo: previous)

    #expect(bytes.range(of: Data("\u{1B}[3J".utf8)) == nil)
    #expect(bytes.range(of: Data("after".utf8)) != nil)
    #expect(bytes.range(of: Data("history".utf8)) == nil)
    #expect(bytes.range(of: Data("\u{1B}[2;4H".utf8)) != nil)
}

@Test func semanticReplayUsesFullReplacementAtMirrorStateBoundaries() throws {
    let previous = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a",
        stateSeq: 1,
        columns: 16,
        rows: 2,
        text: "before"
    )
    let next = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a",
        stateSeq: 2,
        columns: 16,
        rows: 2,
        text: "after"
    )
    let resized = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a",
        stateSeq: 2,
        columns: 17,
        rows: 2,
        text: "resized"
    )
    let alternate = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 2,
        columns: 16,
        rows: 2,
        rowSpans: [.init(row: 0, column: 0, text: "alternate")],
        activeScreen: .alternate
    )
    let scrollbackClear = Data("\u{1B}[3J".utf8)

    let replacements = [
        next.semanticReplayBytes(comparedTo: nil),
        next.semanticReplayBytes(comparedTo: previous, forceFull: true),
        resized.semanticReplayBytes(comparedTo: previous),
        alternate.semanticReplayBytes(comparedTo: previous)
    ]
    for replacement in replacements {
        #expect(replacement.range(of: scrollbackClear) != nil)
    }
}
