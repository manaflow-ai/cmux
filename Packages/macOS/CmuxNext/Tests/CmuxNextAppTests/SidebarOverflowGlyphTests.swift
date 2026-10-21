import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-20: the group header's "…" more button becomes a vertical ellipsis (⋮), like Chrome's
/// menu button, and every more button in the app is the same one. A sidebar row's and a group
/// header's more button draw their three dots in a column.
@MainActor @Suite(.serialized) struct SidebarOverflowGlyphTests {
    private static let workspace = WorkspaceID("ws-row")
    private static let group = GroupID("grp-header")

    private static func sidebar() -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let member = SidebarWorkspace(id: WorkspaceID("ws-member"), title: "member", kind: .terminal)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(SidebarWorkspace(id: workspace, title: "cmux-next", kind: .terminal)),
                .group(SidebarGroup(id: group, name: "Agents", workspaces: [member])),
            ]),
        ])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    /// The drawn glyph's ink bounds, in pixels: where any pixel is not clear.
    private static func inkSize(_ image: NSImage) throws -> CGSize {
        let width = 64, height = 64
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        try #require(maxX >= minX, "the glyph draws nothing")
        return CGSize(width: maxX - minX + 1, height: maxY - minY + 1)
    }

    @Test func aRowsMoreButtonIsAVerticalEllipsis() throws {
        let sidebar = Self.sidebar()
        let row = try #require(sidebar.list.rowViews[.workspace(Self.workspace)] as? WorkspaceRowView)
        let ink = try Self.inkSize(try #require(row.moreButton.image))
        #expect(ink.height > ink.width * 2, "the row's more glyph is \(ink.width) wide, \(ink.height) tall")
    }

    @Test func aGroupHeadersMoreButtonIsAVerticalEllipsis() throws {
        let sidebar = Self.sidebar()
        let header = try #require(sidebar.list.rowViews[.group(Self.group)] as? GroupHeaderRowView)
        let ink = try Self.inkSize(try #require(header.moreButton.image))
        #expect(ink.height > ink.width * 2, "the group header's more glyph is \(ink.width) wide, \(ink.height) tall")
    }
}
