import AppKit
import CmuxNextDesign
import CmuxNextIcons
import Testing
@testable import CmuxNextHome

/// Home's first-run rows and the Conversations add button draw from the cmux
/// icon registry at the size of the text beside them.
@MainActor @Suite struct HomeRegistryIconTests {
    @Test func firstRunRowsNameTheirRegistryIcon() {
        let view = HomeFirstRunView()
        #expect(view.terminal.icon == .terminalNew)
        #expect(view.agent.icon == .agentChat)
        #expect(view.suggestion.icon == .agentQuestion)
    }

    @Test func aFirstRunGlyphIsRowSizeAndFollowsTheScale() throws {
        let row = HomeFirstRunRow(title: "Open a terminal", icon: .terminalNew)
        let side = CGFloat.iconRowSize(forLabelPointSize: 13)
        let image = try #require(row.glyph.image)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: side, height: side))
        row.applyScale(1.5)
        #expect(row.glyph.image?.size == NSSize(width: CGFloat.iconRowSize(forLabelPointSize: 19.5), height: CGFloat.iconRowSize(forLabelPointSize: 19.5)))
    }

    /// The add glyph fills a full icon box: the pack's plus at the header's
    /// row size draws 7 px of ink where the SF plus it replaced drew 10.
    @Test func theAddButtonIsTheRegistryAdd() throws {
        let list = HomeConversationListView(frame: .zero)
        let image = try #require(list.addButtonImage)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: Metrics.iconSize, height: Metrics.iconSize))
    }

    @Test func selectedConversationRowsLeaveBreathingRoomAroundTheSelectionFill() throws {
        let row = HomeConversationTableRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        row.isSelected = true
        row.isEmphasized = true
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 40,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB,
                                                bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        row.drawSelection(in: row.bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let alphaAt = { (y: Int) in rep.colorAt(x: rep.pixelsWide / 2, y: y)?.alphaComponent ?? 0 }
        #expect(alphaAt(2) < 0.5, "selection fill reaches the top edge: \(alphaAt(2))")
        #expect(alphaAt(rep.pixelsHigh - 3) < 0.5, "selection fill reaches the bottom edge: \(alphaAt(rep.pixelsHigh - 3))")
        #expect(alphaAt(rep.pixelsHigh / 2) > 0, "selection fill did not render")
    }

    @Test func conversationSectionHeadersHaveNoNativeBackgroundOrDivider() throws {
        let row = HomeConversationTableRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 24,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB,
                                                bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(row.bounds)
        row.drawBackground(in: row.bounds)
        row.drawSeparator(in: row.bounds)
        context.flushGraphics()
        for y in 0..<rep.pixelsHigh {
            #expect(rep.colorAt(x: rep.pixelsWide / 2, y: y)?.alphaComponent == 0)
        }
    }

    @Test func chiefConversationRowsUseTheRegistryMarkAndKeepTheirChromeBreathingRoom() throws {
        let list = HomeConversationListView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        list.update(rows: HomeConversationListTests.rows, me: HomeConversationListTests.me)
        let index = try #require(list.lines.firstIndex {
            guard case .row(let row) = $0 else { return false }
            return row.kind == .chief
        })
        let cell = try #require(list.tableView(list.table, viewFor: nil, row: index) as? HomeConversationCellView)
        cell.frame = NSRect(x: 0, y: 0, width: 320, height: HomeConversationCellView.height)
        cell.layoutSubtreeIfNeeded()

        let icon = try #require(cell.avatarGlyph.image)
        #expect(icon.isTemplate)
        #expect(icon.size == NSSize(width: Metrics.iconSize, height: Metrics.iconSize))
        #expect(cell.avatar.isHidden)
        #expect(cell.highlightFrame.height == Metrics.sidebarRowHeight)
        #expect(cell.time.lineBreakMode == NSLineBreakMode.byClipping)
        #expect(cell.time.contentCompressionResistancePriority(for: .horizontal) == .required)
        #expect(cell.title.contentCompressionResistancePriority(for: .horizontal) < .required)
    }
}
