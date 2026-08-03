import CmuxTerminalCore
import Foundation
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

    @Test func removesScrollbackAnchorsAfterRowSpaceInvalidation() throws {
        let viewport = try TerminalOverlayRequest(id: "viewport", text: "always")
            .resolved(anchor: .viewportTop)
        let anchored = try TerminalOverlayRequest(id: "anchored", text: "row")
            .resolved(anchor: .scrollback(
                row: 20,
                rowSpaceRevision: 7,
                sticksToViewportTop: false
            ))
        let sticky = try TerminalOverlayRequest(id: "sticky", text: "pin")
            .resolved(anchor: .scrollback(
                row: 30,
                rowSpaceRevision: 8,
                sticksToViewportTop: true
            ))
        var store = TerminalOverlayStore(overlays: [viewport, anchored, sticky])

        let removed = store.removeInvalidatedScrollbackAnchors(
            currentRowSpaceRevision: 8
        )

        #expect(removed == ["anchored"])
        #expect(store.overlays.map(\.id) == ["viewport", "sticky"])
    }

    @Test func stickyScrollbackRowsHideFollowAndPin() {
        let common = (
            row: 40,
            capturedRowSpaceRevision: UInt64(7),
            sticksToViewportTop: true,
            visibleRows: 20,
            totalRows: 100,
            currentRowSpaceRevision: UInt64(7)
        )

        #expect(TerminalOverlayGeometry.scrollbackPlacement(
            row: common.row,
            capturedRowSpaceRevision: common.capturedRowSpaceRevision,
            sticksToViewportTop: common.sticksToViewportTop,
            viewportTopRow: 10,
            visibleRows: common.visibleRows,
            totalRows: common.totalRows,
            currentRowSpaceRevision: common.currentRowSpaceRevision
        ) == .hidden)
        #expect(TerminalOverlayGeometry.scrollbackPlacement(
            row: common.row,
            capturedRowSpaceRevision: common.capturedRowSpaceRevision,
            sticksToViewportTop: common.sticksToViewportTop,
            viewportTopRow: 30,
            visibleRows: common.visibleRows,
            totalRows: common.totalRows,
            currentRowSpaceRevision: common.currentRowSpaceRevision
        ) == .document)
        #expect(TerminalOverlayGeometry.scrollbackPlacement(
            row: common.row,
            capturedRowSpaceRevision: common.capturedRowSpaceRevision,
            sticksToViewportTop: common.sticksToViewportTop,
            viewportTopRow: 40,
            visibleRows: common.visibleRows,
            totalRows: common.totalRows,
            currentRowSpaceRevision: common.currentRowSpaceRevision
        ) == .viewportTop)
        #expect(TerminalOverlayGeometry.scrollbackPlacement(
            row: common.row,
            capturedRowSpaceRevision: common.capturedRowSpaceRevision,
            sticksToViewportTop: common.sticksToViewportTop,
            viewportTopRow: 41,
            visibleRows: common.visibleRows,
            totalRows: common.totalRows,
            currentRowSpaceRevision: common.currentRowSpaceRevision
        ) == .viewportTop)
        #expect(TerminalOverlayGeometry.scrollbackPlacement(
            row: common.row,
            capturedRowSpaceRevision: common.capturedRowSpaceRevision,
            sticksToViewportTop: common.sticksToViewportTop,
            viewportTopRow: 41,
            visibleRows: common.visibleRows,
            totalRows: common.totalRows,
            currentRowSpaceRevision: 8
        ) == .invalidated)
    }

    @Test func stripFrameMatchesOneTerminalGridRow() throws {
        let frame = try #require(TerminalOverlayGeometry.gridStripFrame(
            containerFrame: CGRect(x: 12, y: 20, width: 820, height: 500),
            columns: 80,
            cellSize: CGSize(width: 10, height: 21),
            leftPadding: 5,
            topPadding: 7,
            stackIndex: 1
        ))

        #expect(frame == CGRect(x: 17, y: 471, width: 800, height: 21))
    }
}
