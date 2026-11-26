import AppKit
import CmuxNextActions
@testable import CmuxNextDesign
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// The shipped `Resources/theme-files/minimal-sessions.json` applied the way the app applies a theme file: its
/// text read by name (`ThemeFileOverlay.source`), read as an overlay, applied over cmux-next.json's root,
/// parsed (`CmuxConfigSnapshot.parse`), applied to a design (`SettingsApplier`), and handed to the sidebar's
/// model (`SidebarModel.applyListPreferences`, as `SidebarView+Observation` does). Shared with
/// `AAMinimalSessionsGalleryTests`.
@MainActor enum MinimalSessionsPreset {
    static let name = "minimal-sessions"
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let registry = ActionRegistry.standard()

    /// The file's text, found by name the way the app finds it: a user's copy first (none here: an empty
    /// config folder), else the one cmux ships.
    static func text() throws -> String {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "cmux-minimal-sessions-\(UUID().uuidString)", directoryHint: .isDirectory)
        let bundled = AANestedGroupsGalleryTests.repoRoot.appending(path: "Resources/theme-files", directoryHint: .isDirectory)
        let source = try #require(ThemeFileOverlay.source(named: name, configDirectory: home, bundled: bundled))
        return try source.get()
    }

    /// `text` read as the theme file (a user's edited copy passes its own text).
    static func overlay(_ text: String) -> ThemeFileOverlay {
        ThemeFileOverlay(name: name, source: .success(text), base: .object([:]))
    }

    /// The settings the app loads with `overlay` chosen over an otherwise empty cmux-next.json; nil is stock settings.
    static func snapshot(_ overlay: ThemeFileOverlay?) -> CmuxConfigSnapshot {
        let root = JSONValue.object([:])
        return CmuxConfigSnapshot.parse(overlay?.applied(to: root) ?? root, validDensities: SettingsApplier.validDensities,
                                        validMetrics: SettingsApplier.validMetrics)
    }

    /// A design `SettingsApplier` applied `snapshot` to, as every load applies it.
    static func design(_ snapshot: CmuxConfigSnapshot) -> DesignSettings {
        let design = DesignSettings()
        _ = SettingsApplier(design: design, registry: registry).apply(snapshot)
        return design
    }

    /// The shipped file's design.
    static func shippedDesign() throws -> DesignSettings { design(snapshot(overlay(try text()))) }

    /// Runs `body` with the shared design's sidebar and status indicator settings taken from `design` (a row reads
    /// its density, columns and status icon set from `DesignSettings.shared`), then puts back what was there.
    static func with<T>(_ design: DesignSettings, _ body: () throws -> T) rethrows -> T {
        let shared = DesignSettings.shared
        let saved = (sections: shared.sidebarSections, indicator: shared.statusIndicator)
        shared.sidebarSections = design.sidebarSections
        shared.statusIndicator = design.statusIndicator
        StatusIndicatorAppearance.shared.refresh()
        defer {
            shared.sidebarSections = saved.sections
            shared.statusIndicator = saved.indicator
            StatusIndicatorAppearance.shared.refresh()
        }
        return try body()
    }

    /// The list options the sidebar lays `sections` out with under `preferences`.
    static func options(_ preferences: SidebarSectionsPreferences, sections: [SidebarSection]) -> SidebarLayoutOptions {
        let model = SidebarModel(sections: sections)
        model.applyListPreferences(preferences)
        return model.listOptions()
    }

    /// Every state a row's mark says, idle first.
    static let states: [(name: String, activity: StatusIndicatorState, unread: UnreadState)] = [
        ("idle", .idle, .none),
        ("working", .working(progress: nil), .none),
        ("busy", .busy(progress: nil), .none),
        ("blocked", .waiting(kind: .permission), .none),
        ("question", .waiting(kind: .question), .none),
        ("done", .success, .none),
        ("error", .error, .none),
        ("unread", .idle, .dot),
    ]

    static func workspace(_ id: String, _ title: String, activity: StatusIndicatorState = .idle, unread: UnreadState = .none,
                          icon: WorkspaceIcon? = nil) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), title: title, lastActivity: Date(timeIntervalSince1970: 1_800_000_000),
                         agentWorking: activity.isWorking, icon: icon, unread: unread, activity: activity)
    }
}

/// Minimal sessions under load: a thousand long-named rows, a row whose status flips hundreds of times, and the
/// status placement toggled back and forth. The title never moves, the leading mark stays in its slot and never
/// runs into the title, and nothing leaks between placements.
@MainActor @Suite(.serialized, .closesItsWindows) struct MinimalSessionsStressTests {
    private static let width: CGFloat = 280

    /// One reusable row view in a window, as the list's pool hands one view from workspace to workspace.
    @MainActor private final class Harness {
        let window: NSWindow
        let view: WorkspaceRowView

        init(key: SidebarRowKey) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: MinimalSessionsStressTests.width, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: true)
            // `close()` would release a window the test still holds.
            window.isReleasedWhenClosed = false
            view = WorkspaceRowView(key: key)
            window.contentView?.addSubview(view)
        }

        /// Configures the view for `ws` as `row` and lays it out.
        func show(_ ws: SidebarWorkspace, _ row: SidebarRow) {
            if view.key != row.key { view.prepareForReuse(key: row.key) }
            view.frame = NSRect(x: 0, y: 0, width: MinimalSessionsStressTests.width, height: row.height)
            view.configure(ws, row: row)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
    }

    /// `ws`'s row as the layout makes it under `options`, alone in its section.
    private static func row(_ ws: SidebarWorkspace, _ options: SidebarLayoutOptions) throws -> SidebarRow {
        let section = SidebarSection(kind: .machine(MinimalSessionsPreset.machine), nodes: [.workspace(ws)])
        let layout = SidebarLayout.make(sections: [section], metrics: .standard, options: options)
        return try #require(layout.rows.first { $0.key == .workspace(ws.id) })
    }

    /// The leading icon slot of a top-level row: where the leading mark must stay.
    private static var slot: ClosedRange<CGFloat> {
        let columns = SidebarStyle.columns(rowWidth: width, depth: 0)
        return columns.lead...(columns.lead + columns.iconBox)
    }

    /// A title of 200+ characters mixing Latin, CJK, Hangul and emoji (a ZWJ sequence too).
    private static func longTitle(_ index: Int) -> String {
        let parts = ["Refactor the sidebar renderer so rows never shift ", "サイドバーの行が動かないようにする ",
                     "修复侧边栏标题的位置 ", "🚀🧪🛠️👩🏽‍💻 ", "한국어 제목도 아주 길게 "]
        var title = "\(index) "
        var part = index
        while title.count < 220 { title += parts[part % parts.count]; part += 1 }
        return title
    }

    /// (d) The shipped file loads with no diagnostic at either step and sets what makes it a minimal session list.
    @Test func thePresetParsesWithNoDiagnostics() throws {
        let overlay = MinimalSessionsPreset.overlay(try MinimalSessionsPreset.text())
        #expect(overlay.isLoaded)
        #expect(!overlay.isUnparsable)
        #expect(overlay.diagnostics.isEmpty, "\(overlay.diagnostics)")
        // It restyles the sidebar as a whole: every row element, the status and the grouping.
        #expect(overlay.values.count >= 20, "the file sets only \(overlay.values.count) values")
        let snapshot = MinimalSessionsPreset.snapshot(overlay)
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
        let sidebar = snapshot.sidebarSections
        #expect(sidebar.workspaceRow.statusPlacement == .leading)
        #expect(!sidebar.workspaceRow.base.shows(.icon))
        #expect(sidebar.workspaceRow.base.shows(.working))
        // A running program spins too: `progress` is also the busy mark of running work.
        #expect(sidebar.workspaceRow.base.shows(.progress))
        #expect(sidebar.density == .compact)
        #expect(sidebar.textSize == .standard)
        #expect(sidebar.groupBy == .none)
        #expect(sidebar.detailedStatusIcons)
        #expect(!sidebar.showTimestamps)
        #expect(!sidebar.showColors)
        #expect(!sidebar.groupHeaderMemberCount && !sidebar.groupHeaderUnreadCount)
        #expect(snapshot.statusIndicator.iconSet == StatusIconSet.symbols.rawValue)
        // Applied, the design holds the same, and every row the sidebar lays out leads with its status.
        let design = MinimalSessionsPreset.design(snapshot)
        #expect(design.sidebarSections == sidebar)
        #expect(design.statusIndicator.iconSet == StatusIconSet.symbols.rawValue)
        let options = MinimalSessionsPreset.options(design.sidebarSections, sections: [])
        #expect(options.workspaceRow.statusPlacement == .leading && options.detailedStatus)
    }

    /// (a) A thousand workspaces with 200+ character titles (CJK, emoji), every status: each row the layout makes
    /// leads with its status, and laid out its title starts on the one x, clear of the leading mark.
    @Test func aThousandLongRowsKeepOneTitleXClearOfTheMark() throws {
        let design = try MinimalSessionsPreset.shippedDesign()
        try MinimalSessionsPreset.with(design) {
            let states = MinimalSessionsPreset.states
            let workspaces = (0..<1000).map { index in
                let state = states[index % states.count]
                return MinimalSessionsPreset.workspace("w\(index)", Self.longTitle(index), activity: state.activity, unread: state.unread)
            }
            let sections = [SidebarSection(kind: .machine(MinimalSessionsPreset.machine), nodes: workspaces.map { .workspace($0) })]
            let options = MinimalSessionsPreset.options(design.sidebarSections, sections: sections)
            let rows = SidebarLayout.make(sections: sections, metrics: .standard, options: options).rows
            let byKey = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            let expectedX = SidebarStyle.workspaceTitleX(icon: nil, treeDepth: 0, reservesIconSlot: true) + WorkspaceRowView.labelInset
            let harness = Harness(key: .workspace(workspaces[0].id))
            defer { harness.window.close() }
            var problems: [String] = []
            var titleXs: [String: Set<CGFloat>] = [:]
            for (index, ws) in workspaces.enumerated() {
                guard let row = byKey[.workspace(ws.id)] else {
                    problems.append("\(ws.id): no row")
                    continue
                }
                if row.content?.statusLeads != true { problems.append("\(ws.id): its row does not lead with its status") }
                harness.show(ws, row)
                let view = harness.view, name = states[index % states.count].name
                let title = view.title.frame
                titleXs[name, default: []].insert(title.minX)
                if title.minX != expectedX { problems.append("\(ws.id) \(name): title at \(title.minX), want \(expectedX)") }
                if let mark = view.leadingStatusMark {
                    if mark.isHidden { problems.append("\(ws.id) \(name): the leading mark is hidden") }
                    if mark.frame.maxX > title.minX { problems.append("\(ws.id) \(name): the mark \(mark.frame) runs into the title \(title)") }
                } else if states[index % states.count].activity != .idle {
                    problems.append("\(ws.id) \(name): no leading mark")
                }
            }
            #expect(problems.isEmpty, "\(problems.count) problems, first: \(problems.prefix(5))")
            #expect(Set(titleXs.values.flatMap { $0 }) == [expectedX], "title x by status: \(titleXs)")
            #expect(titleXs.count == states.count)
        }
    }

    /// (b) One row with an icon, cycled idle, working, blocked, done, error 500 times and back to idle: its title
    /// never moves, the leading mark stays inside the icon slot, and the icon is back whenever the row is idle.
    /// The shipped file hides the icon; this is its copy with `sidebar.workspaceRow.icon` turned on.
    @Test func rapidStatusChangesNeverMoveTheTitle() throws {
        let design = try MinimalSessionsPreset.shippedDesign()
        design.sidebarSections.workspaceRow.base.shown.insert(.icon)
        try MinimalSessionsPreset.with(design) {
            let cycle: [StatusIndicatorState] = [.idle, .working(progress: nil), .waiting(kind: .permission), .success, .error]
            var ws = MinimalSessionsPreset.workspace("cycle", "Fix the build", icon: .symbol("star"))
            let options = MinimalSessionsPreset.options(design.sidebarSections, sections: [])
            let harness = Harness(key: .workspace(ws.id))
            defer { harness.window.close() }
            harness.show(ws, try Self.row(ws, options))
            let origin = harness.view.title.frame.origin
            #expect(!harness.view.icon.isHidden, "the idle row shows its icon")
            let slot = Self.slot
            var problems: [String] = []
            for round in 0..<500 {
                let steps = round == 499 ? cycle + [StatusIndicatorState.idle] : cycle
                for activity in steps {
                    ws.activity = activity
                    ws.agentWorking = activity.isWorking
                    harness.show(ws, try Self.row(ws, options))
                    let view = harness.view
                    if view.title.frame.origin != origin { problems.append("\(round) \(activity): title at \(view.title.frame.origin), was \(origin)") }
                    if activity == .idle {
                        if view.icon.isHidden { problems.append("\(round): the idle row's icon is hidden") }
                        if view.leadingStatusMark != nil { problems.append("\(round): an idle row draws a leading mark") }
                    } else if let mark = view.leadingStatusMark {
                        // Half a point either way: the mark sits on the pixel grid.
                        if mark.frame.minX < slot.lowerBound - 0.5 || mark.frame.maxX > slot.upperBound + 0.5 {
                            problems.append("\(round) \(activity): the mark \(mark.frame) leaves the slot \(slot)")
                        }
                        if !view.icon.isHidden { problems.append("\(round) \(activity): the icon shows under the mark") }
                    } else {
                        problems.append("\(round) \(activity): no leading mark")
                    }
                }
            }
            #expect(problems.isEmpty, "\(problems.count) problems, first: \(problems.prefix(5))")
            #expect(!harness.view.icon.isHidden, "the row ends idle with its icon")
        }
    }

    /// What a row draws: each subview's visibility and, when shown, its frame.
    private struct Drawn: Equatable {
        var hidden: Bool
        var frame: NSRect
    }

    private static func drawn(_ view: NSView) -> [Drawn] {
        view.subviews.map { Drawn(hidden: $0.isHidden, frame: $0.isHidden ? .zero : $0.frame) }
    }

    /// (c) A configured row (an icon, an agent working) toggled leading and trailing 100 times draws, each time it
    /// is back on trailing, exactly what its first trailing layout drew: no state of the leading pass stays.
    @Test func togglingThePlacementLeaksNothing() throws {
        let design = try MinimalSessionsPreset.shippedDesign()
        design.sidebarSections.workspaceRow.base.shown.insert(.icon)
        try MinimalSessionsPreset.with(design) {
            let ws = MinimalSessionsPreset.workspace("toggle", "Fix the build", activity: .working(progress: nil), icon: .symbol("star"))
            let leading = MinimalSessionsPreset.options(design.sidebarSections, sections: [])
            var trailing = leading
            trailing.workspaceRow.statusPlacement = .trailing
            let leadingRow = try Self.row(ws, leading), trailingRow = try Self.row(ws, trailing)
            #expect(leadingRow.content?.statusLeads == true && trailingRow.content?.statusLeads == false)
            let harness = Harness(key: .workspace(ws.id))
            defer { harness.window.close() }
            harness.show(ws, trailingRow)
            let first = Self.drawn(harness.view)
            #expect(harness.view.leadingStatusMark == nil)
            #expect(!harness.view.icon.isHidden)
            harness.show(ws, leadingRow)
            let firstLeading = Self.drawn(harness.view)
            #expect(firstLeading != first, "leading draws as trailing does")
            var mismatches: [Int] = []
            for round in 0..<100 {
                harness.show(ws, leadingRow)
                if Self.drawn(harness.view) != firstLeading { mismatches.append(-round - 1) }
                harness.show(ws, trailingRow)
                if Self.drawn(harness.view) != first { mismatches.append(round) }
            }
            #expect(mismatches.isEmpty, "rounds that drew otherwise (negative: leading): \(mismatches.prefix(10))")
            #expect(Self.drawn(harness.view) == first)
        }
    }
}
