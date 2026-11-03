import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence msg 11983: "make sure sidebar has blue, orange/yellow for needs attention, and red for errors".
/// Each status dot color has one meaning in every row kind: blue (`systemBlue`) is unread or new, orange
/// (`systemOrange`) needs attention (a permission prompt, a question, waiting on the user), red (`systemRed`)
/// is an error. A group header, open or collapsed, rolls up its subtree's most urgent state: red, then orange,
/// then blue. Measured on the real ``SidebarView``: each row's visible status glyph and the color its
/// indicator draws, in light and dark. Each case prints a `STATUSCOLOR|` line so a fleet log shows them.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarStatusColorTests {
    enum Meaning: String, CustomStringConvertible {
        case unread, attention, error
        var description: String { rawValue }
        /// The one system color this meaning draws in.
        var color: NSColor {
            switch self {
            case .unread: .systemBlue
            case .attention: .systemOrange
            case .error: .systemRed
            }
        }
    }

    static let home = LayoutItemID("itm_home"), bandWaiting = LayoutItemID("itm_wait"), bandError = LayoutItemID("itm_err")
    static let unread = WorkspaceID("sc-unread"), waiting = WorkspaceID("sc-waiting"), failed = WorkspaceID("sc-failed")
    static let nestedFailed = WorkspaceID("sc-nested-failed")
    /// Open: members unread, waiting and failed (red wins).
    static let allThree = GroupID("sc-all-three")
    /// Open: members unread and waiting (orange wins).
    static let twoStates = GroupID("sc-two")
    /// Collapsed: one unread member (blue).
    static let foldedUnread = GroupID("sc-folded-unread")
    /// Open: an unread member and a subgroup with a waiting member (orange from the subtree).
    static let parent = GroupID("sc-parent"), child = GroupID("sc-child")
    static let topKey = SidebarRowKey.block(SidebarLayoutDocument.topSectionID.rawValue)

    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        var list: SidebarListView { sidebar.list }

        init(dark: Bool) {
            _ = NSApplication.shared
            typealias T = SidebarStatusColorTests
            func ws(_ id: String, unread: UnreadState = .none, activity: StatusIndicatorState = .idle) -> SidebarWorkspace {
                SidebarWorkspace(id: WorkspaceID(id), title: id, agentWorking: activity != .idle, unread: unread, activity: activity)
            }
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, items: [
                LayoutItem(id: T.home, ref: .builtIn(.home)),
                LayoutItem(id: T.bandWaiting, ref: .workspace("sc-band-wait")),
                LayoutItem(id: T.bandError, ref: .workspace("sc-band-err")),
            ])
            let block = SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.topSectionID.rawValue)), nodes: [])
            var child = SidebarGroup(id: T.child, name: "Child", color: .yellow, workspaces: [ws("sc-child-waiting", activity: .waiting)])
            child.parent = T.parent
            var deepChild = SidebarGroup(id: GroupID("sc-deep"), name: "Deep", color: .green,
                                         workspaces: [ws(T.nestedFailed.rawValue, activity: .error)])
            deepChild.parent = T.allThree
            let nodes: [SidebarNode] = [
                .workspace(ws(T.unread.rawValue, unread: .dot)),
                .workspace(ws(T.waiting.rawValue, activity: .waiting(kind: .permission))),
                .workspace(ws(T.failed.rawValue, activity: .error)),
                .group(SidebarGroup(id: T.allThree, name: "All three", color: .blue, workspaces: [
                    ws("sc-a-unread", unread: .dot), ws("sc-a-waiting", activity: .waiting), ws("sc-a-failed", activity: .error),
                ])),
                .group(deepChild),
                .group(SidebarGroup(id: T.twoStates, name: "Two", color: .purple, workspaces: [
                    ws("sc-b-unread", unread: .dot), ws("sc-b-waiting", activity: .waiting),
                ])),
                .group(SidebarGroup(id: T.foldedUnread, name: "Folded", color: .cyan, isCollapsed: true, workspaces: [
                    ws("sc-c-unread", unread: .dot),
                ])),
                .group(SidebarGroup(id: T.parent, name: "Parent", color: .orange, workspaces: [ws("sc-p-unread", unread: .dot)])),
                .group(child),
            ]
            model = SidebarModel(sections: [block, SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: nil)
            let layout = SidebarLayoutDocument(sections: [top])
            model.layout = layout
            var homeInfo = SidebarItemInfo(title: "Home", symbol: "house")
            homeInfo.unreadDot = true
            var waitInfo = SidebarItemInfo(title: "Band waiting", symbol: "textformat")
            (waitInfo.textOnly, waitInfo.activity) = (true, .waiting)
            var errInfo = SidebarItemInfo(title: "Band failed", symbol: "textformat")
            (errInfo.textOnly, errInfo.activity) = (true, .error)
            model.itemInfo = [T.home: homeInfo, T.bandWaiting: waitInfo, T.bandError: errInfo]
            model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { _ in nil })
            sidebar = SidebarView(model: model, design: DesignSettings.shared)
            sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 900)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 280, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView?.addSubview(sidebar)
            window.orderFrontRegardless()
            sidebar.layoutSubtreeIfNeeded()
            list.reload(animated: false)
            sidebar.layoutSubtreeIfNeeded()
            list.fitToClip()
            sidebar.layoutSubtreeIfNeeded()
            for row in list.rowViews.values {
                row.layoutSubtreeIfNeeded()
                if let block = row as? SidebarBlockRowView { block.region.itemViews.values.forEach { $0.layoutSubtreeIfNeeded() } }
            }
        }

        func bandRow(_ id: LayoutItemID) throws -> NSView {
            let block = try #require(list.rowViews[SidebarStatusColorTests.topKey] as? SidebarBlockRowView, "no top block")
            return try #require(block.region.itemViews[id], "no band row \(id.rawValue)")
        }

        func row(_ key: SidebarRowKey) throws -> NSView { try #require(list.rowViews[key], "no row \(key)") }
    }

    /// The colors every visible status glyph in `row` draws in (sRGB), resolved in `appearance`.
    static func glyphColors(in row: NSView, appearance: NSAppearance) -> [NSColor] {
        var found: [NSColor] = []
        func visit(_ view: NSView) {
            guard !view.isHidden, view.alphaValue > 0.01 else { return }
            if let indicator = view as? StatusIndicatorView, indicator.showsGlyph {
                appearance.performAsCurrentDrawingAppearance { indicator.updateLayer() }
                let plan = indicator.indicator.plan
                if let colors = indicator.indicator.colors, let ink = NSColor(cgColor: colors.color(for: plan.tint))?.usingColorSpace(.sRGB) {
                    found.append(ink)
                }
            }
            view.subviews.forEach(visit)
        }
        visit(row)
        return found
    }

    static func matches(_ ink: NSColor, _ meaning: Meaning, appearance: NSAppearance) -> Bool {
        var expected: NSColor?
        appearance.performAsCurrentDrawingAppearance { expected = meaning.color.usingColorSpace(.sRGB) }
        guard let expected else { return false }
        return abs(ink.redComponent - expected.redComponent) < 0.02 && abs(ink.greenComponent - expected.greenComponent) < 0.02
            && abs(ink.blueComponent - expected.blueComponent) < 0.02
    }

    @Test(arguments: [false, true])
    func everyRowKindDrawsEachMeaningInItsOneColor(_ dark: Bool) throws {
        // The static look (Reduce Motion) draws done as a green check, not the blue dot. Pin it off:
        // a runner with the system's Reduce Motion on (Blacksmith macOS) otherwise fails here.
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let label = dark ? "dark" : "light"
        let h = Harness(dark: dark)
        defer { h.window.close() }
        let appearance = try #require(h.window.appearance)
        let cases: [(String, NSView, Meaning)] = [
            ("home unread", try h.bandRow(Self.home), .unread),
            ("band waiting", try h.bandRow(Self.bandWaiting), .attention),
            ("band error", try h.bandRow(Self.bandError), .error),
            ("row unread", try h.row(.workspace(Self.unread)), .unread),
            ("row permission", try h.row(.workspace(Self.waiting)), .attention),
            ("row error", try h.row(.workspace(Self.failed)), .error),
            ("nested member error", try h.row(.workspace(Self.nestedFailed)), .error),
            ("open header red > orange > blue", try h.row(.group(Self.allThree)), .error),
            ("open header orange > blue", try h.row(.group(Self.twoStates)), .attention),
            ("collapsed header blue", try h.row(.group(Self.foldedUnread)), .unread),
            ("open parent rolls up its subgroup", try h.row(.group(Self.parent)), .attention),
            ("nested open header", try h.row(.group(Self.child)), .attention),
        ]
        for (name, row, meaning) in cases {
            let inks = Self.glyphColors(in: row, appearance: appearance)
            print("STATUSCOLOR|\(label)|\(name)|want \(meaning)|\(inks.map { String(format: "%.3f,%.3f,%.3f", $0.redComponent, $0.greenComponent, $0.blueComponent) })")
            #expect(inks.count == 1, "\(label) \(name): \(inks.count) status glyphs, want one")
            for ink in inks {
                #expect(Self.matches(ink, meaning, appearance: appearance), "\(label) \(name): draws \(ink), want \(meaning) (\(meaning.color))")
            }
        }
    }

    /// The header roll-up order on the model: red over orange over blue, whatever the member order.
    @Test func theRollUpOrderIsErrorThenAttentionThenUnread() {
        func ws(_ id: String, unread: UnreadState = .none, activity: StatusIndicatorState = .idle) -> SidebarWorkspace {
            SidebarWorkspace(id: WorkspaceID(id), title: id, unread: unread, activity: activity)
        }
        let unread = ws("u", unread: .dot), waiting = ws("w", activity: .waiting), failed = ws("f", activity: .error)
        for members in [[unread, waiting, failed], [failed, waiting, unread], [waiting, failed, unread]] {
            #expect(SidebarGroup(id: GroupID("g"), name: "g", workspaces: members).statusRollUp(collapsed: false) == .error)
        }
        for members in [[unread, waiting], [waiting, unread]] {
            #expect(SidebarGroup(id: GroupID("g"), name: "g", workspaces: members).statusRollUp(collapsed: false) == .waiting)
        }
        #expect(SidebarGroup(id: GroupID("g"), name: "g", workspaces: [unread]).statusRollUp(collapsed: false) == .success)
        let zeroUnread = ws("zero", unread: .count(0))
        #expect(SidebarGroup(id: GroupID("g"), name: "g", workspaces: [zeroUnread]).statusRollUp(collapsed: false) == .idle)
        let working = ws("b", activity: .working)
        // A collapsed header keeps its loading spinner when nothing needs the user; an open one leaves it to its rows.
        #expect(SidebarGroup(id: GroupID("g"), name: "g", workspaces: [working]).statusRollUp(collapsed: true) == .working)
        #expect(SidebarGroup(id: GroupID("g"), name: "g", workspaces: [working]).statusRollUp(collapsed: false) == .idle)
        #expect(SidebarGroup(id: GroupID("g"), name: "g", workspaces: [working, unread]).statusRollUp(collapsed: true) == .success)
    }
}
