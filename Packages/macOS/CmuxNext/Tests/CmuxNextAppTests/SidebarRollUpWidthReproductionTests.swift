import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// Native geometry reproduction, not a production fix. Forty synthetic child workspaces pass
/// through SidebarLayout's real tree aggregation before configuring the production row view.
/// Run this suite alone: it temporarily changes shared design settings synchronously.
/// Always exports light/dark PNGs and measured geometry JSON to the package's .build/rollup-capture;
/// CMUX_SIDEBAR_ROLLUP_CAPTURE_DIR overrides that directory. JSON is written before imaging,
/// and captures precede expectations, so a red run leaves evidence. No fixed expected failure.
@MainActor @Suite(.serialized) struct SidebarRollUpWidthReproductionTests {
    @Test func foldedParentRetainsTitleRoomAtMinimumSidebarWidth() throws {
        _ = NSApplication.shared
        let design = DesignSettings.shared
        let oldDensity = design.densityTokens, oldSections = design.sidebarSections
        let oldFont = design.overrides[.chromeFontSize], oldScale = design.interfaceScale
        let oldTheme = ThemeScope.app.store.input
        defer {
            design.densityTokens = oldDensity
            design.sidebarSections = oldSections
            design.setOverride(.chromeFontSize, oldFont)
            design.interfaceScale = oldScale
            _ = ThemeScope.app.store.apply(oldTheme)
        }
        design.density = .compact
        design.sidebarSections.density = .compact
        design.setOverride(.chromeFontSize, 16)
        design.interfaceScale = 1

        let sidebarWidth = Metrics.sidebarMinWidth
        let inset = SidebarStyle.horizontalInset
        // SidebarListView.frame(for:), for an ungrouped root row: no gutter or rail reach.
        let rowWidth = sidebarWidth - 2 * inset - SidebarStyle.rowTrailingTrim
        try #require(sidebarWidth == 160 && rowWidth == 152.5,
                     "Fixture needs default compact metrics; got sidebar \(sidebarWidth), row \(rowWidth)")
        try #require(SidebarStyle.titleFont.pointSize == 16)

        let parentID = WorkspaceID("rollup-parent")
        var parent = SidebarWorkspace(id: parentID, title: "Release work")
        parent.activity = .working
        parent.agentWorking = true
        var nodes: [SidebarNode] = [.workspace(parent)]
        var parents: [WorkspaceID: WorkspaceID] = [:]
        var states: [WorkspaceID: SidebarAgentState] = [parentID: .running]
        let kinds: [SidebarAgentState] = [.blocked, .failed, .running, .finishedUnread]
        for (kindIndex, kind) in kinds.enumerated() {
            for n in 0..<10 {
                let id = WorkspaceID("rollup-child-\(kindIndex)-\(n)")
                var child = SidebarWorkspace(id: id, title: "Task \(kindIndex)-\(n)")
                // The production state reader turns an idle lane with unread output into finishedUnread.
                if kind == .finishedUnread { child.unread = .dot }
                states[id] = kind == .finishedUnread ? .idle : kind
                parents[id] = parentID
                nodes.append(.workspace(child))
            }
        }
        let section = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: nodes)
        var options = SidebarLayoutOptions()
        options.sessionTree = SidebarSessionTreeState(parents: parents, states: states, collapsed: [parentID])
        // No extra tab disclosure, tab count, icon, PR badge, unread mark or keycap on this parent.
        options.showWorkspaceTabs = false
        let layout = SidebarLayout.make(sections: [section], metrics: .standard, options: options)
        let row = try #require(layout.rows.first { $0.key == .workspace(parentID) })
        let content = try #require(row.content)
        try #require(content.treeFold == .collapsed)
        try #require(content.rollUp == SidebarTreeRollUp(blocked: 10, failed: 10, running: 10, unread: 10))
        try #require(layout.rows.filter { if case .workspace = $0.key { true } else { false } }.count == 1)

        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = ProcessInfo.processInfo.environment["CMUX_SIDEBAR_ROLLUP_CAPTURE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? package.appendingPathComponent(".build/rollup-capture", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        print("SidebarRollUpWidthReproduction capture directory: \(out.path)")

        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let theme = dark ? "Soft Blue" : "Soft Blue Light"
            let input = try AANestedGroupsGalleryTests.input(theme)
            _ = ThemeScope.app.store.apply(input)
            // A normal minimum-sized native window hosts a cropped sidebar row fixture.
            // This is not a claim that the complete live sidebar was captured.
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 320),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let root = RollUpCaptureRoot(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
            root.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            root.wantsLayer = true
            window.contentView = root
            let scope = ThemeScope(level: .room)
            scope.setOverride(ThemeSpec(theme), input: input, animated: false)
            scope.root(root)
            root.layer?.backgroundColor = scope.perform { Palette.sidebarBackground.withAlphaComponent(1) }.cgColor
            let view = WorkspaceRowView(key: row.key)
            root.addSubview(view)
            view.configure(parent, row: row, badgeStyle: .trailing)
            view.frame = NSRect(x: inset, y: 16, width: rowWidth, height: row.height)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            try #require(view.activity.showsGlyph, "The fixture includes the parent's working-state mark")
            try #require(!view.rollUp.isHidden)

            let geometry = Geometry(mode: mode, sidebarWidth: sidebarWidth, row: box(view.frame),
                                    title: box(view.title.frame), rollUp: box(view.rollUp.frame),
                                    rollUpIntrinsicWidth: view.rollUp.intrinsicContentSize.width,
                                    fold: box(view.treeFoldButton.frame), leadingContentEdge: inset,
                                    bodyFontSize: SidebarStyle.titleFont.pointSize,
                                    badgeFontSize: SidebarStyle.badgeFont.pointSize)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let measured = try encoder.encode(geometry)
            print("SidebarRollUpWidthReproduction \(String(decoding: measured, as: UTF8.self))")
            try measured.write(to: out.appendingPathComponent("rollup-\(mode).json"))
            window.orderFrontRegardless()
            for child in AANestedGroupsGalleryTests.all(root) {
                child.layoutSubtreeIfNeeded(); child.needsDisplay = true; child.displayIfNeeded()
            }
            CATransaction.flush()
            let crop = NSRect(x: 0, y: 0, width: sidebarWidth, height: row.height + 32)
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: crop))
            root.cacheDisplay(in: crop, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("rollup-\(mode).png"))
            #expect(view.title.frame.width > 0, "\(mode): collapsed parent must retain nonzero title room")
            #expect(view.rollUp.frame.minX >= inset,
                    "\(mode): chips start at \(view.rollUp.frame.minX), before the leading content edge \(inset)")
        }
    }

    private func box(_ rect: CGRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }

    private struct Geometry: Encodable {
        let mode: String
        let sidebarWidth: CGFloat
        let row: [CGFloat] // root coordinates; remaining frames are row-local
        let title: [CGFloat]
        let rollUp: [CGFloat]
        let rollUpIntrinsicWidth: CGFloat
        let fold: [CGFloat]
        let leadingContentEdge: CGFloat
        let bodyFontSize: CGFloat
        let badgeFontSize: CGFloat
    }
}

private final class RollUpCaptureRoot: NSView {
    override var isFlipped: Bool { true }
}
