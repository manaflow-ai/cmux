import AppKit
import typealias CmuxNextBridge.StripTabID
import CmuxNextChiefMemory
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

extension InternalPageID {
    /// The built-in Memory Inspector (memory-inspector-native-DESIGN.md): one pane tab per Chief.
    nonisolated static let chiefMemory = InternalPageID(rawValue: "chief-memory")
}

/// Which Chief a Memory Inspector tab shows, kept as the tab's route so a
/// relaunched tab shows the same Chief: `local` (this Mac's default Chief),
/// `local:<chief id>` (another Chief this Mac runs) or `server:<machine id>`
/// (the Chief on a paired server).
nonisolated struct ChiefMemoryRoute: Hashable, Sendable {
    enum Place: Hashable, Sendable {
        case local(chief: String?)
        case server(machineID: String)
    }

    var place: Place

    static let defaultChief = ChiefMemoryRoute(place: .local(chief: nil))

    init(place: Place) {
        self.place = place
    }

    init?(_ text: String) {
        if text == "local" {
            place = .local(chief: nil)
        } else if let chief = text.removingPrefix("local:"), !chief.isEmpty {
            place = .local(chief: chief)
        } else if let machine = text.removingPrefix("server:"), !machine.isEmpty {
            place = .server(machineID: machine)
        } else {
            return nil
        }
    }

    var description: String {
        switch place {
        case .local(nil): "local"
        case .local(let chief?): "local:\(chief)"
        case .server(let machine): "server:\(machine)"
        }
    }
}

private nonisolated extension String {
    func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

/// Owns the Memory Inspector tabs: native SwiftUI, one per Chief, in the
/// pane beside the docked Home (the Home right column). Every read and
/// change goes over a daemon connection (`chief-inspect`), never a localhost
/// server.
@MainActor
final class ChiefMemoryPageService: InternalPageProvider {
    private weak var services: AppServices?
    private var routes: [String: ChiefMemoryRoute] = [:]
    /// The route the next new tab shows (set right before it opens).
    private var nextRoute: ChiefMemoryRoute?

    init(services: AppServices) {
        self.services = services
    }

    var page: InternalPageID { .chiefMemory }
    var title: String { ChiefInspectorStrings.pageTitle }
    var symbol: String { "brain" }

    /// The tab showing `route`'s Chief, selected; a new one in the Home right
    /// column when none is open. Nil when no window can show it.
    @discardableResult
    func open(_ route: ChiefMemoryRoute, in window: WindowController?, focus: Bool) -> String? {
        guard let services, let window, let content = window.workspaceContent else { return nil }
        // The model's panes (a parked workspace's view may be behind the tree).
        for model in content.modelPanes {
            let keys = services.pages.tabIDs(in: model.id) + model.tabs.compactMap { services.pages.storeKey(of: $0.id) }
            if let shown = keys.first(where: { routes[$0] == route }) {
                if focus, let pane = content.controller(for: model) {
                    pane.select(services.pages.stripID(showing: shown, in: pane) ?? StripTabID(shown))
                    pane.focusContent()
                }
                return shown
            }
        }
        nextRoute = route
        defer { nextRoute = nil }
        guard services.pages.openNew(.chiefMemory, in: window, focus: focus) != nil else { return nil }
        return routes.first { $0.value == route }?.key
    }

    /// Whether the workspace `window` names shows a Memory Inspector tab (the Home header's
    /// Memory toggle is on). An observable read: the window's workspace, the tree's page tabs and
    /// the app-only page tabs.
    func isShown(in window: WindowController) -> Bool {
        _ = window.state.workspaceID
        guard let content = window.workspaceContent, let services else { return false }
        if !Self.tabs(in: content.workspace).isEmpty { return true }
        return services.pages.tab(of: .chiefMemory, inPanes: content.modelPanes.map(\.id)) != nil
    }

    /// Closes every Memory Inspector tab of the workspace `window` names; false when it shows none.
    func closeShown(in window: WindowController) -> Bool {
        guard let services, let content = window.workspaceContent else { return false }
        var closed = false
        // The model's panes, each closed through its controller (the one close path). A pane the
        // daemon added while the workspace was parked off screen has no controller until it shows.
        for model in content.modelPanes {
            guard let pane = content.controller(for: model) else { continue }
            let store = Self.tabs(in: model).map { StripTabID($0.id) }
            let local = services.pages.tabIDs(in: model.id).filter { LocalPageTab.page(of: $0) == .chiefMemory }.map { StripTabID($0) }
            guard !(store + local).isEmpty else { continue }
            pane.close(store + local)
            closed = true
        }
        return closed
    }

    /// The tree's Memory Inspector page tabs in `workspace` (any Chief's).
    static func tabs(in workspace: WorkspaceModel) -> [TabModel] {
        workspace.screens.flatMap(\.panes).flatMap { tabs(in: $0) }
    }

    /// The tree's Memory Inspector page tabs in `pane`.
    static func tabs(in pane: PaneModel) -> [TabModel] {
        pane.tabs.filter { $0.page == InternalPageID.chiefMemory.rawValue }
    }

    /// The daemon in front of `route`'s brain; nil while it is not connected.
    func connection(for route: ChiefMemoryRoute) -> DaemonConnection? {
        switch route.place {
        case .local: services?.home.connection
        case .server(let machine): services?.machines.server(machine)?.daemon.connection
        }
    }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let route = routes[key] ?? nextRoute ?? .defaultChief
        routes[key] = route
        let chief: String? = switch route.place {
        case .local(let named): named
        case .server: nil
        }
        let source = DaemonChiefMemorySource(chief: chief) { [weak self] in self?.connection(for: route) }
        // A delete asks first, in a cmux dialog over this tab only.
        let anchor = WeakView()
        let model = ChiefMemoryInspectorModel(source: source) { target, _ in
            let spec = ChiefMemoryInspectorView.deleteDialog(for: target)
            let scope: CmuxDialogScope = if let view = anchor.view { .tab(view) } else { .app }
            return await CmuxDialogCenter.shared.present(spec, in: scope).button == ChiefMemoryInspectorView.deleteButton
        }
        let view = NSHostingView(rootView: ChiefMemoryInspectorView(model: model))
        anchor.view = view
        return view
    }

    func tabClosed(_ key: String) {
        routes[key] = nil
    }

    func route(for key: String) -> String? { routes[key]?.description }

    func restore(_ route: String, for key: String) {
        if let route = ChiefMemoryRoute(route) { routes[key] = route }
    }
}

/// The tab's view, held weakly, for its delete dialog's scope.
@MainActor
private final class WeakView {
    weak var view: NSView?
}
