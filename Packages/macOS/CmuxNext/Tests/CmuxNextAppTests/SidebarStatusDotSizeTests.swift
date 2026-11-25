import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence msg 19696 (a Retina shot of the sidebar's right edge): "dots are different size now which is
/// very bad". The blue unread dots (Home, a workspace row) drew 8 pt and the orange needs-attention dot 6 pt.
/// Every status dot the sidebar draws (blue unread, orange needs attention, any other dot) is one diameter
/// and centers on the one trailing column, in every row kind: Home, a pinned band row, selected and
/// unselected workspace rows, open, collapsed and pinned group headers rolling up their members, and nested rows,
/// at every density and text size, light and dark. A dot is measured by its drawn ink (the mask or shape
/// the layer paints), not its view's box. The spinner and the red error mark are not dots and keep their
/// sizes. Each case prints a `DOTSIZE|` line so a fleet log shows the numbers.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarStatusDotSizeTests {
    static let home = LayoutItemID("itm_dz_home"), pinnedItem = LayoutItemID("itm_dz_pinned")
    static let selected = WorkspaceID("dz-selected"), unread = WorkspaceID("dz-unread"), waiting = WorkspaceID("dz-waiting")
    static let failed = WorkspaceID("dz-failed"), member = WorkspaceID("dz-member"), nested = WorkspaceID("dz-nested")
    static let nestedWaiting = WorkspaceID("dz-nested-waiting"), idle = WorkspaceID("dz-idle")
    static let rollsUpOrange = GroupID("dz-rolls-up-orange"), open = GroupID("dz-open"), sub = GroupID("dz-sub")
    static let reference = GroupID("dz-reference"), pinnedGroup = GroupID("dz-pinned-group")
    static let topKey = SidebarRowKey.block(SidebarLayoutDocument.topSectionID.rawValue)

    /// A sidebar with one of each dot: Home unread, a pinned band row that needs you, a selected unread row,
    /// an unread row, a row that needs you, a failed row, a collapsed header rolling up orange, an open
    /// header rolling up its nested members, and nested rows, unread and needing you.
    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        var list: SidebarListView { sidebar.list }

        init(width: CGFloat, appearance: NSAppearance.Name) {
            _ = NSApplication.shared
            typealias T = SidebarStatusDotSizeTests
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, items: [
                LayoutItem(id: T.home, ref: .builtIn(.home)),
                LayoutItem(id: T.pinnedItem, ref: .workspace("dz-band-pinned")),
            ])
            var subgroup = SidebarGroup(id: T.sub, name: "Nested", color: .yellow, workspaces: [
                SidebarWorkspace(id: T.nested, title: "Nested unread", unread: .dot),
                SidebarWorkspace(id: T.nestedWaiting, title: "Nested needs you", agentWorking: true, activity: .waiting),
            ])
            subgroup.parent = T.open
            let nodes: [SidebarNode] = [
                .workspace(SidebarWorkspace(id: T.selected, title: "Selected unread", unread: .dot)),
                .group(SidebarGroup(id: T.reference, name: "Reference", color: .grey,
                                    workspaces: [SidebarWorkspace(id: T.idle, title: "Idle workspace")])),
                .group(SidebarGroup(id: T.open, name: "Open group", color: .blue,
                                    workspaces: [SidebarWorkspace(id: T.member, title: "Member unread", unread: .dot)])),
                .group(subgroup),
                .group(SidebarGroup(id: T.rollsUpOrange, name: "Rolls up orange", color: .purple, isCollapsed: true,
                                    workspaces: [SidebarWorkspace(id: WorkspaceID("dz-folded-waiting"), title: "Folded needs you",
                                                                  agentWorking: true, activity: .waiting)])),
                .workspace(SidebarWorkspace(id: T.unread, title: "Tailscale SSH audit", unread: .dot)),
                .workspace(SidebarWorkspace(id: T.waiting, title: "Needs you", agentWorking: true, activity: .waiting)),
                .workspace(SidebarWorkspace(id: T.failed, title: "Failed", activity: .error)),
            ]
            // The band's own block: a pinned group header, collapsed, rolling up a member that needs you.
            let block = SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.topSectionID.rawValue)), nodes: [
                .group(SidebarGroup(id: T.pinnedGroup, name: "Pinned group", color: .green, isCollapsed: true, isPinned: true,
                                    workspaces: [SidebarWorkspace(id: WorkspaceID("dz-pinned-member"), title: "Pinned member needs you",
                                                                  agentWorking: true, activity: .waiting)])),
            ])
            model = SidebarModel(sections: [block, SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: T.selected)
            model.layout = SidebarLayoutDocument(sections: [top])
            var homeInfo = SidebarItemInfo(title: "Home", symbol: "house")
            homeInfo.unreadDot = true
            var pinnedInfo = SidebarItemInfo(title: "Pinned needs you", symbol: "textformat")
            pinnedInfo.textOnly = true
            pinnedInfo.leadingPin = true
            pinnedInfo.activity = .waiting
            pinnedInfo.workspace = WorkspaceID("dz-band-pinned")
            model.itemInfo = [T.home: homeInfo, T.pinnedItem: pinnedInfo]
            model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { _ in nil })
            sidebar = SidebarView(model: model, design: DesignSettings.shared)
            sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 900)
            // Clear of the pointer, so no row starts hovered.
            let pointer = NSEvent.mouseLocation
            window = NSWindow(contentRect: NSRect(x: pointer.x + 40, y: pointer.y - 450, width: width, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
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

        func bandRow(_ id: LayoutItemID) throws -> SidebarItemRowView {
            let block = try #require(list.rowViews[SidebarStatusDotSizeTests.topKey] as? SidebarBlockRowView, "no top block")
            return try #require(block.region.itemViews[id], "no band row \(id.rawValue)")
        }

        func row(_ key: SidebarRowKey) throws -> NSView { try #require(list.rowViews[key], "no row \(key)") }

        /// Every row that must show a dot, by name.
        func dotRows() throws -> [(String, NSView)] {
            typealias T = SidebarStatusDotSizeTests
            return [
                ("home", try bandRow(T.home)), ("pinnedNeedsYou", try bandRow(T.pinnedItem)),
                ("selectedUnread", try row(.workspace(T.selected))), ("unread", try row(.workspace(T.unread))),
                ("needsYou", try row(.workspace(T.waiting))), ("memberUnread", try row(.workspace(T.member))),
                ("nestedUnread", try row(.workspace(T.nested))), ("nestedNeedsYou", try row(.workspace(T.nestedWaiting))),
                ("headerRollsUpOrange", try row(.group(T.rollsUpOrange))), ("openHeaderRollUp", try row(.group(T.open))),
                ("pinnedHeaderRollsUpOrange", try row(.group(T.pinnedGroup))),
            ]
        }

        /// The trailing column's x: where the reference group's chevron centers.
        func columnX() throws -> CGFloat {
            let header = try #require(list.rowViews[.group(SidebarStatusDotSizeTests.reference)] as? GroupHeaderRowView)
            let chevron = try #require(header.debugDisclosure)
            return list.convert(chevron.frame, from: header).midX
        }
    }

    /// One drawn dot: what drew it, its ink in list points, and its color's name.
    struct Dot: CustomStringConvertible {
        var what: String
        var ink: CGRect
        var description: String {
            "\(what)@x\((ink.midX * 100).rounded() / 100) d\((ink.width * 100).rounded() / 100)x\((ink.height * 100).rounded() / 100)"
        }
    }

    /// The ink box of an alpha-only image's pixels at least half covered, in pixels (top-left origin).
    static func alphaBounds(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where bytes[y * w + x] >= 128 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// A status indicator's drawn dot, in its own view's points; nil when its glyph is not a dot.
    static func dotInk(_ view: StatusIndicatorView) -> CGRect? {
        let layer = view.indicator
        switch layer.plan.glyph {
        case .mark(.vector(.dot)):
            // Rendered as the layer renders its mask, at 4 pixels a point so the box reads to a quarter point.
            let scale: CGFloat = 4
            guard let mask = layer.debugMarkMask(scale: scale), let px = alphaBounds(mask) else { return nil }
            let rect = layer.debugGlyphRect, k = rect.width / CGFloat(mask.width)
            return CGRect(x: rect.minX + px.minX * k, y: rect.minY + px.minY * k, width: px.width * k, height: px.height * k)
        case .dot:
            guard let shape = layer.glyphLayer, let path = shape.path else { return nil }
            return path.boundingBoxOfPath.offsetBy(dx: shape.frame.minX, dy: shape.frame.minY)
        default:
            return nil
        }
    }

    /// Every visible dot in `row`, in list points, and the non-dot marks it draws (named, for the log).
    static func dots(in row: NSView, named name: String, list: SidebarListView) -> (dots: [Dot], marks: [String]) {
        var dots: [Dot] = [], marks: [String] = []
        func visit(_ view: NSView) {
            guard !view.isHidden, SidebarTrailingColumnTests.drawnAlpha(view, below: list) > 0.01 else { return }
            if let indicator = view as? StatusIndicatorView {
                guard indicator.showsGlyph else { return }
                if let ink = dotInk(indicator) {
                    dots.append(Dot(what: "\(name).\(indicator.state)", ink: list.convert(ink, from: indicator)))
                } else {
                    marks.append("\(name).\(indicator.state)=\(indicator.indicator.plan.glyph)")
                }
                return
            }
            if let badge = view as? UnreadBadgeView, badge.state == .dot {
                dots.append(Dot(what: "\(name).unreadBadge", ink: list.convert(badge.bounds, from: badge)))
            }
            view.subviews.forEach(visit)
        }
        visit(row)
        return (dots, marks)
    }

    nonisolated struct Look: CustomTestStringConvertible, Sendable {
        var density: SidebarDensity
        var textSize: SidebarTextSize
        var dark: Bool
        var appearance: NSAppearance.Name { dark ? .darkAqua : .aqua }
        var testDescription: String { "\(density.rawValue)/text-\(textSize.rawValue)/\(dark ? "dark" : "light")" }
    }

    nonisolated static let looks: [Look] = SidebarTextSize.allCases.flatMap { textSize in
        SidebarDensity.allCases.flatMap { density in [false, true].map { Look(density: density, textSize: textSize, dark: $0) } }
    }

    @Test(arguments: looks)
    func everyStatusDotIsOneDiameterOnOneColumn(_ look: Look) throws {
        // Pinned off: under the system's Reduce Motion (some fleet Macs) done draws a check, not the dot.
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try SidebarGroupRailAlignmentTests.with(look.density, .off, textSize: look.textSize) {
            let h = Harness(width: 280, appearance: look.appearance)
            defer { h.window.close() }
            let column = try h.columnX()
            var all: [Dot] = [], others: [String] = []
            for (name, row) in try h.dotRows() {
                let (dots, marks) = Self.dots(in: row, named: name, list: h.list)
                #expect(!dots.isEmpty, "\(look.testDescription): \(name) draws no dot (marks \(marks))")
                all += dots
                others += marks
            }
            others += Self.dots(in: try h.row(.workspace(Self.failed)), named: "failed", list: h.list).marks
            print("DOTSIZE|\(look.testDescription)|column \(column)|\(all.map(\.description).joined(separator: " "))|not dots: \(others.joined(separator: " "))")
            let reference = try #require(all.first)
            for dot in all {
                #expect(abs(dot.ink.width - dot.ink.height) <= 0.5, "\(look.testDescription): \(dot) is not round")
                #expect(abs(dot.ink.width - reference.ink.width) <= 0.5,
                        "\(look.testDescription): \(dot) is not the diameter of \(reference)")
                #expect(abs(dot.ink.midX - column) <= 0.5, "\(look.testDescription): \(dot) centers off the column \(column)")
            }
        }
    }
}
