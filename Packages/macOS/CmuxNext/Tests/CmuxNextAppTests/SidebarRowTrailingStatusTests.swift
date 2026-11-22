import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-19: "There should only ever be a single unread indicator for the right side",
/// "nothing should ever be on the left side besides the favicon", and "there is slightly too much
/// space between the favicon and the name of the workspace". A workspace row's leading slot draws
/// only its favicon or icon; its one state glyph (the Ready dot, the Working spinner, a waiting or
/// error glyph) draws in the trailing slot, exactly where a text-only row draws it. Since #27598 (Leo's shared
/// grid) the favicon draws at its glyph size centered in the grid's icon column box, and the title's text starts
/// one grid gap (`LayoutGrid.gap`) after that box: the text column every leading-icon row shares.
@MainActor @Suite(.serialized) struct SidebarRowTrailingStatusTests {
    private static let favicon = WorkspaceID("ws-favicon")
    private static let emoji = WorkspaceID("ws-emoji")
    private static let text = WorkspaceID("ws-text")

    private static let image: CGImage = {
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return context.makeImage()!
    }()

    private static func sidebar(unread: UnreadState = .count(1), activity: StatusIndicatorState = .idle, working: Bool = false,
                                style: SidebarRowBadgeStyle = .corner) -> SidebarView {
        func workspace(_ id: WorkspaceID, _ icon: WorkspaceIcon?) -> SidebarWorkspace {
            var ws = SidebarWorkspace(id: id, title: "cmux-next workspace", lastActivity: Date().addingTimeInterval(-60),
                                      icon: icon, kind: .terminal, unread: unread, activity: activity)
            ws.agentWorking = working
            return ws
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(workspace(favicon, .favicon(SidebarFavicon(image)))),
            .workspace(workspace(emoji, .emoji("🦊"))),
            .workspace(workspace(text, nil)),
        ])])
        model.rowBadgeStyle = style
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func row(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
    }

    /// Every visible state glyph under `row` (the badge and the activity indicator), in the row's coordinates.
    private static func glyphs(_ row: WorkspaceRowView) -> [NSRect] {
        var found: [NSRect] = []
        func walk(_ view: NSView) {
            for child in view.subviews where !child.isHidden && child.alphaValue > 0 {
                if child is StatusIndicatorView, child.frame.width > 0 { found.append(row.convert(child.bounds, from: child)) }
                walk(child)
            }
        }
        walk(row)
        return found
    }

    @Test(arguments: [false, true]) func aRowWithAFaviconShowsItsOneStateGlyphOnTheRight(working: Bool) throws {
        let sidebar = working ? Self.sidebar(unread: .none, activity: .working, working: true) : Self.sidebar()
        let textRow = try Self.row(sidebar, Self.text)
        let textGlyph = try #require(Self.glyphs(textRow).first, "the text-only row draws no glyph")
        for id in [Self.favicon, Self.emoji] {
            let row = try Self.row(sidebar, id)
            #expect(!row.icon.isHidden && row.icon.frame.width > 0, "\(id): the icon does not draw")
            let glyphs = Self.glyphs(row)
            #expect(glyphs.count == 1, "\(id) working \(working): \(glyphs.count) state glyphs")
            let glyph = try #require(glyphs.first)
            #expect(!glyph.intersects(row.icon.frame), "\(id): the glyph sits on the icon (\(glyph) on \(row.icon.frame))")
            #expect(glyph.minX > row.title.frame.minX, "\(id): the glyph is not on the trailing side")
            // One slot: the same place a text-only row draws it.
            #expect(abs(glyph.midX - textGlyph.midX) < 0.5, "\(id): \(glyph) is not in the text row's slot \(textGlyph)")
            #expect(row.rowBadge.look != .corner, "\(id): the badge still uses the icon-corner look")
        }
    }

    @Test func theFaviconToTitleGapIsChromeLike() throws {
        let sidebar = Self.sidebar(unread: .none)
        for id in [Self.favicon, Self.emoji] {
            let row = try Self.row(sidebar, id)
            // The icon frame is the grid's icon column box; the favicon draws at the glyph size, centered in it.
            #expect(abs(row.icon.frame.width - SidebarStyle.iconColumnBox) < 0.5, "\(id): icon box \(row.icon.frame.width)")
            #expect(SidebarStyle.kindGlyphSize <= row.icon.frame.width, "\(id): the glyph outgrows its column box")
            // The title starts one grid gap after the box, on the shared text column.
            let gap = row.title.frame.minX - row.icon.frame.maxX
            #expect(abs(gap - LayoutGrid.gap) < 0.5, "\(id): icon box to title gap \(gap)")
            let text = SidebarStyle.columns(rowWidth: row.bounds.width).text
            #expect(abs(row.title.frame.minX - text) < 0.5, "\(id): the title starts at \(row.title.frame.minX), the text column at \(text)")
        }
    }
}
