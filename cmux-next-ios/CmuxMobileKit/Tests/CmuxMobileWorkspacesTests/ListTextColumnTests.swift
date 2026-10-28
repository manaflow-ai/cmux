#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileWorkspaces

/// SPEC 4.2.1: the Workspaces list has one text column. Section titles, group
/// titles and row titles start at the same x; the status dot and the group
/// chevron hang in the gutter before it.
@MainActor @Suite struct ListTextColumnTests {
    nonisolated static let sizes: [DynamicTypeSize] = [.small, .large, .xLarge, .xxLarge, .xxxLarge, .accessibility1, .accessibility3]

    @Test(arguments: sizes) func sectionGroupAndRowTitlesShareOneColumn(size: DynamicTypeSize) {
        let row = WorkspaceRow.textLeading(size)
        #expect(SectionTitle.leading(size) == row)
        #expect(GroupHeaderLabel.titleLeading(size) == row)
        #expect(row == CmuxMobileListColumn.plain(size).text)
    }

    @Test func plainGutterIs32AtLargeAndGrowsWithTheText() {
        #expect(CmuxMobileListColumn.plain(.large).text == 32)
        let widths = Self.sizes.map { CmuxMobileListColumn.plain($0).text }
        #expect(widths == widths.sorted())
        #expect(CmuxMobileListColumn.plain(.xxLarge).text > 32)
    }

    @Test(arguments: sizes) func groupedIconColumnIsCappedAndTheGapFixed(size: DynamicTypeSize) {
        let column = CmuxMobileListColumn.grouped(size)
        #expect(column.mark <= CmuxMobileListColumn.groupedIcon * 2)
        #expect(column.text == column.mark + 14)
        if size == .large { #expect(column.text == 36) }
    }

    @Test func drawerLabelStartsAtTheTeamNames() {
        let theme = CmuxMobileTheme.standard
        #expect(SidebarTeamRow.textLeading == theme.metrics.sideMargin + theme.metrics.teamAvatar + SidebarTeamRow.avatarGap)
    }

    // MARK: Rendered rows

    /// The first column with ink at or after `from` points, in points.
    private func inkStart(_ view: some View, width: CGFloat, size: DynamicTypeSize, from: CGFloat) throws -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: width).dynamicTypeSize(size).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let w = image.width, h = image.height
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = try #require(context.data)
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let first = Int(from * 2)
        for x in first..<w {
            for y in 0..<h where pixels[(y * w + x) * 4 + 3] > 96 {
                return CGFloat(x) / 2
            }
        }
        Issue.record("no ink after \(from) pt")
        return -1
    }

    /// The group header's name and a workspace row's title start within a
    /// point of each other (the glyphs' side bearings differ), at the text
    /// column; the chevron and the dot sit in the gutter before it.
    @Test(arguments: [DynamicTypeSize.large, .xxLarge]) func renderedGroupTitleStartsAtTheRowTitle(size: DynamicTypeSize) throws {
        let column = CmuxMobileListColumn.plain(size).text
        let ws = Workspace(id: "w", macID: "m", title: "Workspace", directory: "~", tabs: [], lastActivityAt: Date(timeIntervalSince1970: 0),
                           needsAttention: true, hasActivityTime: false)
        let row = WorkspaceRow(workspace: ws, status: .needsYou)
        let group = GroupHeaderLabel(group: MacWorkspaceGroup(id: "g", name: "Workspaces", color: "red"), count: 2)
        // The gutter has ink (the needs-you dot, the chevron) before the column.
        let rowGutter = try inkStart(row, width: 390, size: size, from: 0)
        let groupGutter = try inkStart(group, width: 390, size: size, from: 0)
        #expect(rowGutter < column - 4)
        #expect(groupGutter < column - 4)
        let rowTitle = try inkStart(row, width: 390, size: size, from: column - 0.5)
        let groupTitle = try inkStart(group, width: 390, size: size, from: column - 0.5)
        #expect(abs(rowTitle - groupTitle) <= 1, "row title at \(rowTitle) pt, group title at \(groupTitle) pt")
        #expect(rowTitle - column <= 2, "row title at \(rowTitle) pt, column at \(column) pt")
    }
}
#endif
