import CmuxTerminalCore
import Testing

@Suite struct TerminalOverlayTests {
    @Test func validatesAndNormalizesProducerInput() throws {
        let request = try TerminalOverlayRequest(
            id: "agent.latest-message",
            text: "first\r\n\u{001B}[31msecond\u{0000}",
            anchor: .scrollbackTop,
            horizontalAlignment: .right
        )

        #expect(request.id == "agent.latest-message")
        #expect(request.text == "first\n[31msecond")
        #expect(request.anchor == .scrollbackTop)
        #expect(request.horizontalAlignment == .right)
    }

    @Test func rejectsInvalidIdentifiersAndEmptyText() {
        #expect(throws: TerminalOverlayValidationError.invalidIdentifier) {
            try TerminalOverlayRequest(id: "bad id", text: "content")
        }
        #expect(throws: TerminalOverlayValidationError.emptyText) {
            try TerminalOverlayRequest(id: "valid", text: " \n\t ")
        }
    }

    @Test func keyedUpsertPreservesOrder() throws {
        let first = try TerminalOverlayRequest(id: "first", text: "one")
            .resolved(anchor: .viewportTop)
        let second = try TerminalOverlayRequest(id: "second", text: "two")
            .resolved(anchor: .viewportTop)
        let replacement = try TerminalOverlayRequest(id: "first", text: "updated")
            .resolved(anchor: .viewportTop)
        var store = TerminalOverlayStore()

        store.upsert(first)
        store.upsert(second)
        store.upsert(replacement)

        #expect(store.overlays.map(\.id) == ["first", "second"])
        #expect(store.overlays.first?.text == "updated")
        let removedFirst = store.remove(id: "first")
        #expect(removedFirst)
        #expect(store.overlays.map(\.id) == ["second"])
        let removedRemaining = store.removeAll()
        #expect(removedRemaining == 1)
    }

    @Test func resolvesScrollbackRowsInBottomUpDocumentCoordinates() throws {
        let origin = try #require(TerminalOverlayGeometry.scrollbackOverlayOriginY(
            documentHeight: 8_020,
            row: 356,
            totalRows: 400,
            cellHeight: 20,
            topPadding: 10,
            overlayHeight: 100
        ))

        #expect(origin == 790)
        #expect(TerminalOverlayGeometry.scrollbackOverlayOriginY(
            documentHeight: 8_020,
            row: 400,
            totalRows: 400,
            cellHeight: 20,
            topPadding: 10,
            overlayHeight: 100
        ) == nil)
    }
}
