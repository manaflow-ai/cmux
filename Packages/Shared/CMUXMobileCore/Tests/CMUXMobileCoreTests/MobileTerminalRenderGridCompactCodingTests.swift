import Foundation
import Testing
@testable import CMUXMobileCore

/// A 40-row screen where every row uses its own style, like a colorful TUI.
private func styledScreen() throws -> MobileTerminalRenderGridFrame {
    let styles = [MobileTerminalRenderGridFrame.Style(id: 0, background: "#101010")]
        + (1...40).map { id in
            MobileTerminalRenderGridFrame.Style(
                id: id,
                foreground: String(format: "#%02X%02X%02X", id * 5, 255 - id * 5, 128),
                foregroundSource: .palette,
                foregroundPaletteIndex: id,
                bold: id.isMultiple(of: 2),
                underline: id.isMultiple(of: 3)
            )
        }
    return try MobileTerminalRenderGridFrame(
        surfaceID: "8C0A57A4-7F1B-4D0B-9C39-2F4E8B1A6D10",
        stateSeq: 9,
        renderEpoch: "epoch",
        renderRevision: 4,
        columns: 80,
        rows: 40,
        cursor: .init(row: 39, column: 2),
        styles: styles,
        rowSpans: (0..<40).map { row in
            .init(row: row, column: 0, styleID: row + 1, text: "row \(row)")
        },
        anchor: .screen,
        historyRows: 120
    )
}

@Test func renderGridDeltaCarriesOnlyReferencedStylesAndTheEraseStyle() throws {
    let delta = try styledScreen().filteredRows([7], full: false)

    #expect(delta.styles.map(\.id) == [0, 8])
    #expect(delta.rowSpans.map(\.styleID) == [8])
    // Replay erases cleared cells with style 0 and paints spans by id; both
    // must produce the same bytes as the delta built from the whole table.
    var unpruned = delta
    unpruned.styles = try styledScreen().styles
    #expect(delta.vtPatchBytes() == unpruned.vtPatchBytes())
}

@Test func renderGridCompactEncodingRoundTripsFullsAndDeltas() throws {
    let full = try styledScreen()
    let delta = try full.filteredRows([3, 4], full: false, deltaBaseRenderRevision: 3)
    let viewportDelta = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "s",
        stateSeq: 1,
        columns: 4,
        rows: 2,
        text: "ab\n",
        full: false,
        changedRows: [0]
    )
    for frame in [full, delta, viewportDelta] {
        let data = try JSONEncoder().encode(frame)
        #expect(try MobileTerminalRenderGridFrame.decode(data) == frame)
    }
}

@Test func renderGridCompactEncodingOmitsDecoderDefaults() throws {
    let delta = try styledScreen().filteredRows([7], full: false)
    let object = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(delta)) as? [String: Any]
    )
    #expect(object["full"] as? Bool == false)
    for absentKey in ["modes", "scrollback_rows", "scrollback_spans", "scrolled_rows", "active_screen"] {
        #expect(object[absentKey] == nil, "\(absentKey) should be omitted")
    }
    let styles = try #require(object["styles"] as? [[String: Any]])
    let style = try #require(styles.first { $0["id"] as? Int == 8 })
    #expect(style["bold"] as? Bool == true)
    #expect(style["underline"] == nil)
    #expect(style["italic"] == nil)
}

@Test func renderGridStyledDeltaIsSmallNextToTheFullTable() throws {
    let full = try styledScreen()
    let delta = try full.filteredRows([7], full: false)
    var legacyShapedDelta = delta
    legacyShapedDelta.styles = full.styles
    let compactBytes = try JSONEncoder().encode(delta).count
    // The pre-pruning shape shipped the whole table with every flag spelled out.
    let legacyBytes = try JSONSerialization.data(withJSONObject: [
        "styles": full.styles.map { style in
            [
                "id": style.id, "foreground": style.foreground ?? NSNull(),
                "bold": style.bold, "faint": style.faint, "italic": style.italic,
                "underline": style.underline, "blink": style.blink, "inverse": style.inverse,
                "invisible": style.invisible, "strikethrough": style.strikethrough,
                "overline": style.overline,
            ] as [String: Any]
        },
    ]).count
    #expect(compactBytes * 6 < legacyBytes)
}

@Test func renderGridSpliceRoundTripsAndRejectsOtherEvents() throws {
    let payload = try JSONEncoder().encode(styledScreen().filteredRows([1], full: false))
    let envelope = MobileRenderGridEventSplice.envelope(payloadJSON: payload)
    // The envelope is the event the generic path would also accept.
    let object = try #require(try JSONSerialization.jsonObject(with: envelope) as? [String: Any])
    #expect(object["topic"] as? String == "terminal.render_grid")
    // A slice with a nonzero start index, like a frame cut from a read buffer.
    var buffer = Data([0, 0, 0])
    buffer.append(envelope)
    #expect(MobileRenderGridEventSplice.payloadJSON(of: buffer.dropFirst(3)) == payload)
    let other = Data(#"{"kind":"event","topic":"terminal.bytes","payload":{"a":1}}"#.utf8)
    #expect(MobileRenderGridEventSplice.payloadJSON(of: other) == nil)
    let withStream = Data(#"{"kind":"event","topic":"terminal.render_grid","payload":{"a":1},"stream_id":"x"}"#.utf8)
    #expect(MobileRenderGridEventSplice.payloadJSON(of: withStream) == nil)
}
