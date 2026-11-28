import AppKit
import CmuxNextCompat
@testable import CmuxNextSidebar
import CmuxNextDesign
import Testing

/// A `cmux.section/1` app section placed in the sidebar's top region (`apps place`, the default region; docket,
/// cockpit, rex and the Codex threads examples all use it) draws its view, as one placed in the middle does
/// (nightly 4584735850101 r25: top drew nothing, middle drew the Chats card). Built end to end: the reducer's
/// projection of a document holding the app section, the list's arrangement of it, and the sidebar's bands.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarAppTopRegionTests {
    static let session = "s-local"
    static let machine = "sec_m_s-local"
    static let app = "sec_app_codex"
    static let top = "sec_top"
    static let contribution = "local/setup-manaflow-ai-codex-profile#cmux.section/1"

    final class ContentView: NSView {
        var onContent: (() -> Void)?
        private(set) var height: CGFloat = 0
        func deliver() {
            guard window != nil else { return }
            height = 120
            onContent?()
        }
    }

    final class Provider: SidebarAppSectionProvider {
        let view = ContentView()
        var onContentChange: (() -> Void)? { didSet { view.onContent = onContentChange } }
        func title(for contribution: String) -> String? { "Chats" }
        func makeView(for contribution: String) -> NSView? { contribution == SidebarAppTopRegionTests.contribution ? view : nil }
        func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat { view.height }
    }

    static func ref(_ id: String) -> SidebarDocWorkspaceRef { SidebarDocWorkspaceRef(sessionID: session, workspaceID: id) }

    /// The document r25 placed: the app section in `region`, shown title, and the machine's workspaces (none: the
    /// setup workspace was closed before the place).
    static func projection(region: SidebarRegion, workspaces: [String], withTop: Bool = false) -> SidebarDocProjection {
        var items: [String: SidebarDocItem] = [:]
        var machineRows: [SidebarDocRow] = []
        for id in workspaces {
            items["itm_" + id] = SidebarDocItem(id: "itm_" + id, section: machine, body: .workspace(ref(id)))
            machineRows.append(SidebarDocRow(key: "itm_" + id, kind: "item", section: machine, item: "itm_" + id, ref: ref(id)))
        }
        var sections = [
            machine: SidebarDocSection(id: machine, kind: .machine(session: session)),
            app: SidebarDocSection(id: app, kind: .app(contribution: contribution), showsTitle: true, region: region),
        ]
        var topRows: [SidebarDocRow] = []
        if withTop {
            // The built-in top section (Home), which the r25 profile hides (`sidebar.sections.hidden: ["sec_top"]`); the
            // app's order key ("L") sorts before it.
            sections[top] = SidebarDocSection(id: top, kind: .builtin, region: .top)
            items["itm_home"] = SidebarDocItem(id: "itm_home", section: top, body: .builtin("home"))
            topRows = [SidebarDocRow(key: "itm_home", kind: "item", section: top, item: "itm_home")]
        }
        let records = SidebarDocRecords(sections: sections, items: items)
        let appRow = SidebarDocRow(key: app, kind: "section", section: app)
        let rows = region == .top ? [appRow] + topRows + machineRows : topRows + machineRows + [appRow]
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    static func raw(_ workspaces: [String]) -> [CmuxNextSidebar.SidebarSection] {
        [CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                                        nodes: workspaces.map { .workspace(SidebarWorkspace(id: WorkspaceID($0), title: $0)) })]
    }

    /// The sidebar showing `projection` as the bridge does (`SidebarBridge.show`), its app's view delivered.
    static func sidebar(_ projection: SidebarDocProjection, workspaces: [String],
                        hidden: [String] = []) -> (SidebarView, Provider, NSWindow) {
        let store = SidebarDocStore(remote: nil)
        store.shown = projection
        let model = SidebarModel()
        model.docDrag = SidebarDocDrag(document: store, item: { key in
            if case let .workspace(id) = key { return "itm_" + id.rawValue }
            return nil
        }, section: { id in id == .machine(.local) ? machine : nil }, begin: { _ in [:] }, drop: { _, _ in })
        model.layout = projection.layout
        model.sectionCustomization = SidebarProjectionCustomization(hiddenSections: hidden)
        model.setSections(raw(workspaces))
        let sidebar = SidebarView(model: model, design: DesignSettings.shared)
        let provider = Provider()
        sidebar.appSections = provider
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        func settle() {
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.fitToClip()
            sidebar.layoutSubtreeIfNeeded()
        }
        settle()
        provider.view.deliver()
        settle()
        return (sidebar, provider, window)
    }

    static func expectDrawn(_ sidebar: SidebarView, _ provider: Provider, _ label: String) {
        let sections = sidebar.model.sections.map(\.id)
        let rows = sidebar.list.displayed.rows.map(\.key)
        let above = sidebar.aboveRegion.layoutResult.height
        #expect(provider.view.window != nil, "\(label): the app's view is in the window (sections \(sections), rows \(rows), band above \(above))")
        #expect(provider.view.frame.height >= 120, "\(label): the app's view has its content's height: \(provider.view.frame)")
        #expect(provider.view.isHiddenOrHasHiddenAncestor == false, "\(label): the app's view is not hidden")
    }

    @Test(arguments: [[], ["ws-1", "ws-2"]])
    func aTopRegionAppSectionDrawsItsView(workspaces: [String]) {
        let projection = Self.projection(region: .top, workspaces: workspaces)
        #expect(projection.layout.sections.first { $0.id.rawValue == Self.app }?.region == .top, "fixture: the app section is in the top region")
        let (sidebar, provider, window) = Self.sidebar(projection, workspaces: workspaces)
        Self.expectDrawn(sidebar, provider, "top, \(workspaces.count) workspaces")
        window.close()
    }

    /// r25's settings: the profile hides the built-in top section (`sidebar.sections.hidden: ["sec_top"]`), and the
    /// app section sorts before it in the top region. The app section still draws, in either region.
    @Test(arguments: [(SidebarRegion.top, [String]()), (.top, ["ws-1", "ws-2"]), (.middle, []), (.middle, ["ws-1", "ws-2"])])
    func anAppSectionDrawsWithTheTopSectionHidden(region: SidebarRegion, workspaces: [String]) {
        let projection = Self.projection(region: region, workspaces: workspaces, withTop: true)
        let (sidebar, provider, window) = Self.sidebar(projection, workspaces: workspaces, hidden: [Self.top])
        Self.expectDrawn(sidebar, provider, "\(region), sec_top hidden, \(workspaces.count) workspaces")
        window.close()
    }

    /// Without the document (the bands draw the layout): the top band draws the app section.
    @Test(arguments: [SidebarRegion.top, .middle])
    func withoutTheDocumentTheBandDrawsTheAppSection(region: SidebarRegion) {
        let model = SidebarModel()
        model.layout = Self.projection(region: region, workspaces: []).layout
        model.setSections(Self.raw([]))
        let sidebar = SidebarView(model: model, design: DesignSettings.shared)
        let provider = Provider()
        sidebar.appSections = provider
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        provider.view.deliver()
        sidebar.layoutSubtreeIfNeeded()
        Self.expectDrawn(sidebar, provider, "no document, \(region)")
        window.close()
    }

    /// The control r25 drew: the same section in the middle region.
    @Test(arguments: [[], ["ws-1", "ws-2"]])
    func aMiddleRegionAppSectionDrawsItsView(workspaces: [String]) {
        let (sidebar, provider, window) = Self.sidebar(Self.projection(region: .middle, workspaces: workspaces), workspaces: workspaces)
        Self.expectDrawn(sidebar, provider, "middle, \(workspaces.count) workspaces")
        window.close()
    }
}
