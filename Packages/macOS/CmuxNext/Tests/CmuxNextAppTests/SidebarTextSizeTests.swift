import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence msg 17752 (2026-10-30, a ChatGPT sidebar screenshot): "we also need option for sidebar
/// text to be very significantly bigger. this is how big chatgpt is by default, let's match them".
///
/// `sidebar.textSize` scales the list together: titles, details and headers, the leading glyph
/// column and the row and header heights. Larger is the ChatGPT size measured from the screenshot
/// at 2x: 14 pt titles on a 31 pt row pitch. Default keeps the original 12 pt on 26 pt. Every size
/// keeps a group header as tall as a workspace row and a title inside its row. Each case prints a
/// `TEXTSIZE|` line so a fleet log shows the measured numbers.
@MainActor @Suite(.serialized) struct SidebarTextSizeTests {
    private static let group = GroupID("grp-text")
    private static let member = WorkspaceID("ws-text-member")
    private static let loose = WorkspaceID("ws-text-loose")
    private static let long = WorkspaceID("ws-text-long")

    private static func sidebar(_ size: SidebarTextSize, minimal: Bool = false, width: CGFloat = 260) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .group(SidebarGroup(id: group, name: "cmux-next app", color: .blue, isCollapsed: false,
                                    workspaces: [SidebarWorkspace(id: member, title: "member")])),
                .workspace(SidebarWorkspace(id: loose, title: "Work on cmux")),
                .workspace(SidebarWorkspace(id: long, title: "can u start some subagents to demo the feature of cmux next sidebar")),
            ]),
        ])
        let design = DesignSettings()
        design.sidebarSections.textSize = size
        design.sidebarSections.minimal = minimal
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    /// Runs `body` with `sidebar.textSize` set on the shared settings the sidebar tokens read.
    private static func withTextSize<T>(_ size: SidebarTextSize, _ body: () throws -> T) rethrows -> T {
        let saved = DesignSettings.shared.sidebarSections
        DesignSettings.shared.sidebarSections.textSize = size
        DesignSettings.shared.sidebarSections.density = .compact
        defer { DesignSettings.shared.sidebarSections = saved }
        return try body()
    }

    private struct Measured {
        var titlePoints: CGFloat
        var rowHeight: CGFloat
        var rowPitch: CGFloat
        var headerHeight: CGFloat
        var sectionHeaderHeight: CGFloat
        var iconBox: CGFloat
        var headerFontPoints: CGFloat
        var subtitlePoints: CGFloat
    }

    private static func measure(_ size: SidebarTextSize) throws -> Measured {
        try withTextSize(size) {
            let sidebar = sidebar(size)
            let list = sidebar.list
            let row = try #require(list.displayed.row(for: .workspace(loose)), "\(size): no row")
            let view = try #require(list.rowViews[.workspace(loose)] as? WorkspaceRowView, "\(size): no row view")
            let header = try #require(list.displayed.row(for: .group(group)), "\(size): no group header")
            let metrics = SidebarLayoutMetrics.standard
            let measured = Measured(titlePoints: view.title.font.pointSize, rowHeight: row.height, rowPitch: metrics.rowHeight + metrics.rowSpacing,
                                    headerHeight: header.height, sectionHeaderHeight: metrics.sectionHeaderHeight,
                                    iconBox: SidebarStyle.iconBox, headerFontPoints: SidebarStyle.headerFont.pointSize,
                                    subtitlePoints: SidebarStyle.subtitleFont.pointSize)
            print("TEXTSIZE|\(size.rawValue)|title \(measured.titlePoints)|row \(measured.rowHeight)|pitch \(measured.rowPitch)"
                + "|group \(measured.headerHeight)|section \(measured.sectionHeaderHeight)|icon \(measured.iconBox)")
            return measured
        }
    }

    @Test func defaultKeepsTheOriginalSize() throws {
        try DensityTokens.$scoped.withValue(DensityPreset.compact.tokens) {
            let m = try Self.measure(.standard)
            #expect(m.titlePoints == 12)
            #expect(m.rowHeight == 24)
            #expect(m.rowPitch == 26)
        }
    }

    @Test func largerMatchesChatGPT() throws {
        try DensityTokens.$scoped.withValue(DensityPreset.compact.tokens) {
            let m = try Self.measure(.larger)
            #expect(m.titlePoints == 14, "ChatGPT's sidebar titles are 14 pt; got \(m.titlePoints)")
            #expect(m.rowPitch == 31, "ChatGPT's rows are 31 pt apart; got \(m.rowPitch)")
            #expect(m.rowHeight == 29)
        }
    }

    @Test func largeIsBetween() throws {
        try DensityTokens.$scoped.withValue(DensityPreset.compact.tokens) {
            let m = try Self.measure(.large)
            #expect(m.titlePoints == 13)
            #expect(m.rowHeight == 27)
        }
    }

    /// Titles, details, headers, the leading glyph column and every height grow together, never one alone.
    @Test(arguments: DensityPreset.allCases)
    func everyListSizeGrowsTogether(preset: DensityPreset) throws {
        try DensityTokens.$scoped.withValue(preset.tokens) {
            let sizes = try SidebarTextSize.allCases.map { try Self.measure($0) }
            for (smaller, bigger) in zip(sizes, sizes.dropFirst()) {
                #expect(bigger.titlePoints > smaller.titlePoints)
                #expect(bigger.subtitlePoints > smaller.subtitlePoints)
                #expect(bigger.headerFontPoints > smaller.headerFontPoints)
                #expect(bigger.iconBox > smaller.iconBox)
                #expect(bigger.rowHeight > smaller.rowHeight)
                #expect(bigger.sectionHeaderHeight > smaller.sectionHeaderHeight)
            }
        }
    }

    /// At every size, minimal or not, a group header is as tall as a workspace row, and a long title
    /// stays inside its row (it truncates or fades instead of running past the trailing column).
    @Test(arguments: SidebarTextSize.allCases)
    func headersMatchRowsAndTitlesStayInside(size: SidebarTextSize) throws {
        try Self.withTextSize(size) {
            for minimal in [false, true] {
                let sidebar = Self.sidebar(size, minimal: minimal)
                let list = sidebar.list
                let label = "\(size.rawValue)/\(minimal ? "minimal" : "full")"
                let row = try #require(list.displayed.row(for: .workspace(Self.loose)), "\(label): no row")
                let header = try #require(list.displayed.row(for: .group(Self.group)), "\(label): no header")
                #expect(abs(header.height - row.height) <= 0.5, "\(label): header \(header.height) vs row \(row.height)")
                let view = try #require(list.rowViews[.workspace(Self.long)] as? WorkspaceRowView, "\(label): no long row")
                let title = view.convert(view.title.frame, from: view.title.superview)
                #expect(title.maxX <= view.bounds.width + 0.5, "\(label): title ends at \(title.maxX) past \(view.bounds.width)")
                #expect(title.height <= view.bounds.height + 0.5, "\(label): title \(title.height) taller than row \(view.bounds.height)")
                #expect(view.title.font.pointSize == SidebarStyle.titleFont.pointSize, "\(label): title font")
            }
        }
    }

    /// a590's review: at Larger, the narrowest sidebar (``SidebarModel/minimumWidth``, about 181 pt since a875)
    /// still shows a short title whole, and a long one keeps a readable run of text before its fade.
    @Test func largerStaysReadableAtTheNarrowestSidebar() throws {
        try Self.withTextSize(.larger) {
            // The window sets the titlebar part of the minimum (~181 pt); a bare model knows only the 160 pt tunable.
            let narrowest = max(181, SidebarModel(sections: []).minimumWidth)
            let sidebar = Self.sidebar(.larger, width: narrowest)
            let list = sidebar.list
            let short = try #require(list.rowViews[.workspace(Self.loose)] as? WorkspaceRowView)
            let long = try #require(list.rowViews[.workspace(Self.long)] as? WorkspaceRowView)
            let font = SidebarStyle.titleFont
            let natural = ceil(("Work on cmux" as NSString).size(withAttributes: [.font: font]).width)
            let room = short.title.frame.width
            print("TEXTSIZE|narrow \(narrowest)|short room \(room) natural \(natural)|long room \(long.title.frame.width)")
            #expect(font.pointSize == 14)
            #expect(room >= natural, "\(narrowest) pt: \"Work on cmux\" needs \(natural) pt, has \(room)")
            // About ten 14 pt characters before the fade: enough to tell rows apart.
            #expect(long.title.frame.width >= 80, "\(narrowest) pt: a long title has only \(long.title.frame.width) pt")
        }
    }
}
