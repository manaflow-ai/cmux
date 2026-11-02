import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
@testable import CmuxNextSidebar
import Testing

/// Sidebar sweep 2026-10-21 (build ef4dfa4f2f5): groups Work (3 members), Infra (`deploy`) and an empty group.
/// Dragging Infra's header down past the empty group and dropping it left `deploy` with no group rail (the members'
/// line). The rail stayed missing through theme changes and config reloads and came back only when a daemon move
/// rebuilt the list. Rule: once the card lands, every open group with members draws its rail, at its rows.
/// The drop runs through the sidebar document's drag (`SidebarModel.docDrag`), the path the app uses; the second test
/// sends it through a document store, so the list holds the drop's look until the model shows it, as in the app.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarGroupDragRailTests {
    static let section = "sec_m_s1"
    static let work = GroupID("g-work"), infra = GroupID("g-infra"), empty = GroupID("g-empty")

    final class Drops {
        var targets: [SidebarDocTarget] = []
    }

    static func ws(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    static func sections(_ order: [GroupID]) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let groups: [GroupID: SidebarGroup] = [
            work: SidebarGroup(id: work, name: "Work", color: .blue, workspaces: ["docs", "web", "api"].map(ws)),
            infra: SidebarGroup(id: infra, name: "Infra", color: .green, workspaces: [ws("deploy")]),
            empty: SidebarGroup(id: empty, name: "Empty group", color: .red, workspaces: []),
        ]
        return [SidebarSection(kind: .machine(machine), nodes: [.workspace(ws("scratch"))] + order.compactMap { groups[$0].map { .group($0) } })]
    }

    /// `document`: the app's document store the drop goes to, when it has one.
    static func list(_ drops: Drops, document: SidebarDocStore? = nil,
                     send: ((_ items: [String], _ target: SidebarDocTarget) -> Void)? = nil) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let model = SidebarModel(sections: sections([work, infra, empty]), activeWorkspaceID: WorkspaceID("scratch"))
        let members: Set<String> = ["docs", "web", "api", "deploy"]
        model.docDrag = SidebarDocDrag(document: document, item: { key in
            switch key {
            case let .workspace(id): "w_\(id.rawValue)"
            case let .group(group): "g_\(group.rawValue)"
            default: nil
            }
        }, section: { _ in section }, begin: { _ in
            var table: [String: SidebarDocAcceptance] = [section: SidebarDocAcceptance(before: false, into: true, after: false)]
            table["w_scratch"] = SidebarDocAcceptance(before: true, into: false, after: true)
            for group in [work, infra, empty] { table["g_\(group.rawValue)"] = SidebarDocAcceptance(before: true, into: false, after: true, refusal: nil) }
            for member in members { table["w_\(member)"] = SidebarDocAcceptance(before: false, into: false, after: false, refusal: "nesting") }
            return table
        }, drop: { [drops] items, target in
            drops.targets.append(target)
            send?(items, target)
        })
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        return (list, window)
    }

    /// Each open group with members: its rail as the list draws it now (nil: none), and where its rows put it.
    static func rails(_ list: SidebarListView) -> [(group: GroupID, shown: (frame: CGRect, alpha: CGFloat)?, expected: CGRect)] {
        let expected = SidebarGroupLine.lines(list.displayed.rows, colors: list.groups) { list.frame(for: $0) }
        let shown = list.groupLineViews.shown
        return expected.map { ($0.group, shown[$0.group], $0.frame) }
    }

    static func describe(_ list: SidebarListView) -> String {
        let rows = list.displayed.rows.map { row -> String in
            "\(row.key)\(row.group.map { " in \($0.rawValue)" } ?? "")\(row.isCollapsed ? " (collapsed)" : "")"
        }
        return "rows \(rows); suppressed \(list.suppressed); lines \(list.groupLineViews.shown.keys.map(\.rawValue).sorted()); "
            + "settling \(list.settling != nil), landing \(list.landing != nil)"
    }

    /// Drags Infra's header down until the card's top is past the empty group's middle, then lets go.
    static func dragInfraPastEmpty(_ list: SidebarListView) throws {
        let header = try #require(list.displayed.row(for: .group(infra)))
        let emptyRow = try #require(list.displayed.row(for: .group(empty)))
        let start = NSPoint(x: 80, y: header.y + header.height / 2)
        list.press = SidebarPress(key: header.key, point: start)
        list.beginDrag(try #require(list.press))
        try #require(list.drag != nil, "the group did not lift")
        let dy = emptyRow.maxY + header.height - start.y
        for step in 1...6 {
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: start.y + dy * CGFloat(step) / 6), to: nil))
        }
        list.finishDrag()
    }

    /// The daemon's echo of the drop: the document's new order, shown as the app's model change shows it.
    static func echo(_ list: SidebarListView) {
        list.model.sections = sections([work, empty, infra])
        list.showModelChange(animates: true)
    }

    /// `moving`: the rows may still spring to their places (a fold moves on the spring where motion is on): a rail is
    /// checked against where it is going, not where its frame is in the flight.
    static func expectRails(_ list: SidebarListView, _ when: String, moving: Bool = false) {
        let rails = rails(list)
        #expect(rails.map(\.group).contains(infra), "\(when): the layout has no Infra rail to draw: \(describe(list))")
        for rail in rails {
            guard let shown = rail.shown else {
                Issue.record("\(when): \(rail.group.rawValue) draws no rail: \(describe(list))")
                continue
            }
            let frame = moving ? list.groupLineViews.lines.first { $0.group == rail.group }?.frame ?? .zero : shown.frame
            #expect(shown.alpha == 1, "\(when): \(rail.group.rawValue)'s rail is see-through (\(shown.alpha))")
            #expect(abs(frame.minY - rail.expected.minY) < 0.5 && abs(frame.height - rail.expected.height) < 0.5,
                    "\(when): \(rail.group.rawValue)'s rail \(frame) is not at its rows \(rail.expected)")
        }
    }

    /// Runs `body` with `ui.animations.newWorkspace` off, its default, then puts the set back. With it on, a group that
    /// opens fades its new rail in from 0 with the members it shows (`foldGroup`, `SidebarGroupLineViews.update`), so
    /// "after Work opens" read the rail mid-fade (alpha 0.0). The setting is process-wide: a suite running in parallel
    /// (`SidebarRowsMoveOnRenderServerTests`, `SidebarInsertWhileDisplayAsleepTests`) can leave it on across an await.
    /// Synchronous, so no other test changes it while `body` runs.
    static func withNewWorkspaceMotionOff<T>(_ body: () throws -> T) rethrows -> T {
        let kinds = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.remove(.newWorkspace)
        defer { DesignSettings.shared.enabledAnimations = kinds }
        return try body()
    }

    /// After the drop shows: the rails, then after another group folds and opens (a fold splices its rows and keeps
    /// the other lines as they are), then after a reload with nothing new (a theme or config change).
    static func expectRailsAfterTheDrop(_ list: SidebarListView) {
        if let landing = list.landing { list.finishLand(landing, then: nil) }
        #expect(list.settling == nil && list.landing == nil, "the drop never settled: \(describe(list))")
        expectRails(list, "after the drop")
        list.model.setGroupCollapsed(work, true)
        expectRails(list, "after Work folds", moving: true)
        list.model.setGroupCollapsed(work, false)
        expectRails(list, "after Work opens", moving: true)
        list.reload(animated: false)
        expectRails(list, "after a reload")
    }

    /// The card lands before the daemon's echo (the usual order: the move takes a round trip).
    @Test func theRailShowsAfterAGroupDropsPastAnEmptyGroup() throws {
        try Self.withNewWorkspaceMotionOff {
            let drops = Drops()
            let (list, window) = Self.list(drops)
            defer { window.close() }
            Self.expectRails(list, "at rest")
            try Self.dragInfraPastEmpty(list)
            #expect(drops.targets == [SidebarDocTarget(section: Self.section, after: "g_\(Self.empty.rawValue)")], "drops: \(drops.targets)")
            Self.echo(list)
            Self.expectRailsAfterTheDrop(list)
        }
    }

    /// The app's order: the drop goes to the document store, the list keeps the drop's look (the settle) until the
    /// model shows the move, and the card lands into the rows the model put there.
    @Test func theRailShowsAfterADocumentDropSettles() async throws {
        let store = SidebarDocStore(remote: Remote(document: Self.document))
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        try #require(store.isActive, "the store did not load the document")
        let drops = Drops()
        let (list, window) = Self.list(drops, document: store) { items, target in store.move(items, to: target, title: "Move") }
        defer { window.close() }
        try Self.withNewWorkspaceMotionOff {
            try Self.dragInfraPastEmpty(list)
            try #require(list.settling != nil, "the drop did not settle on the document's move: \(Self.describe(list))")
            Self.echo(list)
            Self.expectRailsAfterTheDrop(list)
        }
    }

    /// The home daemon's document for `sections([work, infra, empty])`; its moves never answer (the echo is the test's).
    static let document = Data("""
    {"revision": "1",
     "sections": [{"id": "sec_m_s1", "order": "V", "kind": {"type": "machine", "session_id": "s1"}}],
     "items": [
       {"id": "w_scratch", "section": "sec_m_s1", "order": "a", "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "scratch"}}},
       {"id": "g_g-work", "section": "sec_m_s1", "order": "b", "body": {"type": "group", "name": "Work"}},
       {"id": "w_docs", "section": "sec_m_s1", "parent": "g_g-work", "order": "a", "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "docs"}}},
       {"id": "w_web", "section": "sec_m_s1", "parent": "g_g-work", "order": "b", "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "web"}}},
       {"id": "w_api", "section": "sec_m_s1", "parent": "g_g-work", "order": "c", "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "api"}}},
       {"id": "g_g-infra", "section": "sec_m_s1", "order": "c", "body": {"type": "group", "name": "Infra"}},
       {"id": "w_deploy", "section": "sec_m_s1", "parent": "g_g-infra", "order": "a", "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "deploy"}}},
       {"id": "g_g-empty", "section": "sec_m_s1", "order": "d", "body": {"type": "group", "name": "Empty group"}}
     ]}
    """.utf8)

    @MainActor final class Remote: SidebarDocRemote {
        let document: Data
        init(document: Data) { self.document = document }
        var isAvailable: Bool { true }
        func get() async throws -> Data { document }
        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { try await unanswered() }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply { try await unanswered() }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { try await unanswered() }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { try await unanswered() }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply { try await unanswered() }
        /// The reply comes after the test ends: the drop's settle waits on the model, as on a round trip.
        private func unanswered() async throws -> SidebarDocReply {
            try await Task.sleep(for: .seconds(600))
            throw CancellationError()
        }
    }
}
