import AppKit
import CmuxNextActions
@testable import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import Foundation
import Testing

/// Leo 2026-10-13 (cx-sya4n): "What if they were just colors or symbols or some text."
/// `appearance.statusIndicator.animation: "static"` (Settings > Appearance > Status indicators)
/// stills every status indicator, draws each state as its own shape (never color alone), and
/// names the state: the indicator's tooltip and VoiceOver label everywhere, and a short label
/// beside the mark on a sidebar workspace row.
@MainActor @Suite(.serialized) struct StaticStatusIndicatorTests {
    static let states: [(name: String, state: StatusIndicatorState)] = [
        ("working", .working(progress: nil)), ("busy", .busy(progress: nil)), ("paused", .paused(progress: nil)),
        ("waiting", .waiting(kind: nil)), ("permission", .waiting(kind: .permission)), ("question", .waiting(kind: .question)),
        ("auth", .waiting(kind: .auth)), ("error", .error), ("done", .success),
    ]

    /// Picks Static the way the Settings window does: through the schema's one write path.
    private static func pickStatic() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-static-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings.shared, fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        try await settings.setSetting(at: ["appearance", "statusIndicator", "animation"], to: .string("static"), by: .user)
        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved.contains("\"static\""))
        // The appearance follows DesignSettings through an Observation stream; apply now.
        StatusIndicatorAppearance.shared.apply(StatusIndicatorConfig.current)
        return directory
    }

    private static func sidebar(in window: NSWindow) -> CmuxNextSidebar.SidebarView {
        let workspaces = states.enumerated().map { index, entry in
            SidebarWorkspace(id: WorkspaceID("ws-\(entry.name)"), title: "w\(index)", agentWorking: true, activity: entry.state)
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func tabs() -> [(name: String, cell: TabCell)] {
        func tab(_ name: String, _ change: (inout TabItem) -> Void) -> (String, TabCell) {
            var item = TabItem(id: CmuxNextTabs.TabID("t-\(name)"), title: name)
            change(&item)
            return (name, TabCell(item: item))
        }
        return [
            tab("working") { $0.indicator = .working(progress: nil) },
            tab("busy") { $0.indicator = .busy(progress: nil) },
            tab("waiting") { $0.status = .needsInput },
            tab("permission") { $0.status = .needsInput; $0.blockedKind = .permission },
            tab("question") { $0.status = .needsInput; $0.blockedKind = .question },
            tab("auth") { $0.status = .needsInput; $0.blockedKind = .auth },
            tab("error") { $0.status = .failure },
            tab("done") { $0.status = .success },
        ]
    }

    @Test func staticDrawsAStillDistinctMarkAndAShortLabelForEveryState() async throws {
        let design = DesignSettings.shared
        let before = design.statusIndicator
        defer {
            design.statusIndicator = before
            StatusIndicatorAppearance.shared.apply(StatusIndicatorConfig.current)
        }
        let directory = try await Self.pickStatic()
        defer { try? FileManager.default.removeItem(at: directory) }

        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        if !NSScreen.screens.isEmpty { window.orderFrontRegardless() }
        let sidebar = Self.sidebar(in: window)

        var glyphs: [String: StatusIndicatorPlan.Glyph] = [:]
        var labels: [String: String] = [:]
        for (name, _) in Self.states {
            let row = try #require(sidebar.list.rowViews[.workspace(WorkspaceID("ws-\(name)"))] as? WorkspaceRowView, "\(name)")
            let mark = try #require(row.subviews.lazy.compactMap { $0 as? StatusIndicatorView }.first, "\(name)")
            #expect(!mark.isHidden, "\(name): the row shows no status mark")
            #expect(mark.indicator.plan.animation == nil && mark.indicator.runningAnimation == nil, "\(name) animates")
            #expect(ReduceMotionLoopTests.loops(under: row.layer) == [], "\(name) loops")
            glyphs[name] = mark.indicator.plan.glyph
            let label = mark.themedToolTip ?? ""
            #expect(!label.isEmpty, "\(name): the mark has no tooltip")
            labels[name] = label
            let shown = row.subviews.contains { view in
                guard let field = view as? NSTextField, field !== row.subtitle, !field.isHidden, field.frame.width > 0 else { return false }
                return field.stringValue == label
            }
            #expect(shown, "\(name): the row does not show its label \"\(label)\"")
        }
        #expect(Set(glyphs.values).count == Self.states.count, "two states share a mark: \(glyphs)")
        #expect(Set(labels.values).count == Self.states.count, "two states share a label: \(labels)")

        var tabGlyphs: [String: StatusIndicatorPlan.Glyph] = [:]
        for (name, cell) in Self.tabs() {
            let plan = try #require((cell.spinnerLayer ?? cell.statusGlyphLayer)?.plan, "\(name): the tab draws no mark")
            #expect(plan.animation == nil, "\(name) animates on its tab")
            #expect(ReduceMotionLoopTests.loops(under: cell.layer) == [], "\(name) loops on its tab")
            tabGlyphs[name] = plan.glyph
        }
        #expect(Set(tabGlyphs.values).count == tabGlyphs.count, "two tab states share a mark: \(tabGlyphs)")
    }
}
