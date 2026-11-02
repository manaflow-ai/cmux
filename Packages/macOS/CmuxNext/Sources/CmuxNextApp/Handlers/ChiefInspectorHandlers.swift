import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextHomeEngine
import Foundation
import Observation

/// "Chief: Open Memory Inspector" (palette, `cmux chief memory`, MCP, and the
/// Chief settings panel's Show Memory): the built-in Memory Inspector
/// (memory-inspector-native-DESIGN.md), a native pane tab per Chief in the
/// Home right column that reads and changes the memory over the daemon
/// connection (`chief-inspect`). Arguments: `chief` (a Chief this Mac runs
/// that is not the default) or `server` (the machine id of a paired server
/// whose Chief to show); neither: this Mac's default Chief.
///
/// Fallback: with `CMUX_MEMORY_INSPECTOR_WEB=1` in the app's environment (and
/// `OPTCHAT_INSPECTOR_WEB=1` in the brain's), the old web page opens instead:
/// the local brain host serves it on 127.0.0.1 (optchat-chief
/// inspect/http.rs) behind a token traded for a one-time ticket. In the home
/// workspace it is a tab in the right column (``ChiefInspectorPlacement``,
/// a243); elsewhere a browser tab in a new column right of the focused pane's.
@MainActor
enum ChiefInspectorHandlers {
    static let actionID: ActionID = "chief.openMemoryInspector"
    /// The Home header's Memory toggle (``HomeHeaderPanels``) and the palette's Toggle Memory
    /// Inspector: closes the active window's Memory Inspector tabs when its workspace shows one,
    /// else opens one exactly as ``actionID`` (same arguments, same fallback).
    static let toggleActionID: ActionID = "chief.toggleMemoryInspector"
    /// The old web page instead of the native view (the fallback).
    static var opensWebPage: Bool { ProcessInfo.processInfo.environment["CMUX_MEMORY_INSPECTOR_WEB"] == "1" }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let remotePage = ChiefInspectorPageService(services: context.services)
        context.services.pages.register(remotePage)
        let memory = ChiefMemoryPageService(services: context.services)
        context.services.pages.register(memory)
        registry.bind(actionID, run: { invocation in
            if opensWebPage {
                try openWeb(invocation, remotePage: remotePage, context: context)
                return
            }
            guard let window = context.services.windows.active,
                  memory.open(route(invocation), in: window, focus: invocation.allowsViewChange) != nil else {
                throw ActionWorkFailure(RefusalStrings.noWindowOpen)
            }
        })
        registry.bind(toggleActionID, run: { invocation in
            guard let window = context.services.windows.active else { throw ActionWorkFailure(RefusalStrings.noWindowOpen) }
            if memory.closeShown(in: window) { return }
            _ = context.registry.perform(actionID, invocation: invocation)
        })
    }

    /// The Chief the invocation names (`chief`, `server`), else this Mac's default Chief.
    static func route(_ invocation: ActionInvocation) -> ChiefMemoryRoute {
        if let machine = invocation.arguments["server"]?.stringValue, !machine.isEmpty {
            return ChiefMemoryRoute(place: .server(machineID: machine))
        }
        let chief = invocation.arguments["chief"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return ChiefMemoryRoute(place: .local(chief: chief))
    }

    /// The old web page (the fallback): the local host's page through a
    /// ticket, or a paired server's through its daemon.
    private static func openWeb(_ invocation: ActionInvocation, remotePage: ChiefInspectorPageService,
                                context: AppActionContext) throws {
        let target = try placement(invocation, context: context)
        let muxHome = HomeBrainHost.muxHome(tag: context.services.environment.tag)
        // task-owner: one file read, one ticket request and one tab open; ends
        // with them (a caller such as `cmux action run` waits and gets the failure).
        context.registry.track(Task { @MainActor in
            do {
                // No Chief on this Mac: a paired server's Chief, through its daemon.
                if !(await Task.detached { ChiefInspectorEndpoint.exists(muxHome: muxHome) }.value),
                   let server = remoteChief(context) {
                    try openRemote(server, page: remotePage, placement: target, invocation: invocation, context: context)
                    return nil
                }
                let endpoint = try await Task.detached { try ChiefInspectorEndpoint.read(muxHome: muxHome) }.value
                let url = try await endpoint.ticketURL()
                switch target {
                case .tab(let pane): try await openAsTab(url, in: pane, context: context)
                case .newColumn(let anchor): try await openInNewColumn(url, anchor: anchor, context: context)
                }
                return nil
            } catch {
                let reason = switch error {
                case is ChiefInspectorEndpoint.Missing: ChiefInspectorStrings.noLocalChief
                case let failure as ActionWorkFailure: failure.message
                default: ChiefInspectorStrings.unreachable
                }
                context.daemon.logger.error("memory inspector: \(String(describing: error), privacy: .public)")
                context.registry.refuse(reason)
                return ActionWorkFailure(reason)
            }
        })
    }

    /// A connected paired server whose brain daemon serves `chief-inspect`.
    private static func remoteChief(_ context: AppActionContext) -> ServerMachineSession? {
        context.services.machines.servers.first { $0.daemon.supports(DaemonCapability.chiefInspect.rawValue) }
    }

    /// The remote inspector page in this window, then moved into a new
    /// column right of `anchor`'s column.
    private static func openRemote(_ server: ServerMachineSession, page: ChiefInspectorPageService,
                                   placement: Target,
                                   invocation: ActionInvocation, context: AppActionContext) throws {
        guard let window = context.services.windows.active,
              page.open(machineID: server.machineID, in: window, focus: invocation.allowsViewChange) else {
            throw ActionWorkFailure(RefusalStrings.noWindowOpen)
        }
        // In Home the page stays a tab where the window shows pages (the right column).
        guard case .newColumn(let anchor) = placement else { return }
        if let located = context.allTabs.first(where: { $0.tab.page == InternalPageID.chiefInspector.rawValue }),
           located.pane.id != anchor.id || located.pane.tabs.count > 1 {
            TabMoves.toNewColumn(located.tab, anchor: anchor, services: context.services)
        }
    }

    /// Where the tab goes: in the home workspace a tab in its right column
    /// (``ChiefInspectorPlacement``), else a new column right of
    /// ``anchorPane(_:context:)``.
    private static func placement(_ invocation: ActionInvocation, context: AppActionContext) throws -> Target {
        if let focused = context.scope(invocation).pane?.pane, let screen = homeScreen(of: focused, context: context) {
            let byHandle = Dictionary(screen.panes.map { ($0.handle, $0) }, uniquingKeysWith: { first, _ in first })
            let columns = screen.columns.map { column in
                ChiefInspectorPlacement<CmuxNextDaemon.PaneID>.Column(panes: column.layout.paneIDs, isDock: column.dock != nil)
            }
            switch ChiefInspectorPlacement.resolve(focused: focused.handle, inHome: true, columns: columns) {
            case .tab(let handle)?: if let pane = byHandle[handle] { return .tab(pane) }
            case .newColumn(let handle)?: if let pane = byHandle[handle] { return .newColumn(rightOf: pane) }
            case nil: break
            }
        }
        return .newColumn(rightOf: try anchorPane(invocation, context: context))
    }

    /// The screen of `pane` when it is in the home workspace, else nil.
    private static func homeScreen(of pane: PaneModel, context: AppActionContext) -> ScreenModel? {
        for workspace in context.daemon.store.workspaces where workspace.isAnyHome {
            if let screen = workspace.screens.first(where: { $0.panes.contains { $0 === pane } }) { return screen }
        }
        return nil
    }

    /// Where the inspector tab goes (``placement(_:context:)``).
    enum Target {
        case tab(PaneModel)
        case newColumn(rightOf: PaneModel)
    }

    /// The pane the new column goes right of: the focused (or targeted) pane;
    /// with none (Home is shown), the last pane of the window's workspace
    /// unless that is the home workspace, else of the first user workspace.
    private static func anchorPane(_ invocation: ActionInvocation, context: AppActionContext) throws -> PaneModel {
        let scope = context.scope(invocation)
        // A Home pane never anchors a new column (a243): a user workspace does.
        if let pane = scope.pane, homeScreen(of: pane.pane, context: context) == nil { return pane.pane }
        guard invocation.target == nil || scope.pane != nil else { throw ActionFailure(message: MiscHandlerStrings.noPane) }
        // The home workspace (kind "home") holds only the Chief conversation
        // that the Home page shows: the column goes into a user workspace.
        let user = { (w: WorkspaceModel) in !w.isAnyHome && w.screens.first?.panes.last != nil }
        let workspace = scope.workspace.flatMap { user($0) ? $0 : nil }
            ?? context.daemon.store.workspaces.first(where: user)
        guard let pane = workspace?.screens.first?.panes.last else { throw ActionFailure(message: MiscHandlerStrings.noPane) }
        return pane
    }

    /// A new browser tab at `url` in `pane` (Home's right column), then shown and selected.
    private static func openAsTab(_ url: URL, in pane: PaneModel, context: AppActionContext) async throws {
        guard case let browserTabs = context.services.cache.browserTabs,
              case .open(let choice) = browserTabs.resolve(requested: nil) else {
            throw ActionWorkFailure(MiscHandlerStrings.noBrowser)
        }
        let surface = try await browserTabs.open(choice, in: pane, url: url.absoluteString, profile: nil)
        await reveal(surface, context: context)
    }

    /// Shows and selects the tab of `surface` once the mirror reports it.
    private static func reveal(_ surface: SurfaceID, context: AppActionContext) async {
        let located = try? await ControlDeadline.shared.run(method: "chief-inspector.reveal", deadline: .now + .seconds(5)) { @MainActor in
            for await tab in ObservationStream({ context.allTabs.first { $0.tab.surface == surface } }) {
                if let tab { return tab }
            }
            return nil as LocatedTab?
        }
        if let located = located ?? nil { context.reveal(located) }
    }

    /// A new browser tab at `url` in `anchor`, moved into a new column right
    /// of the anchor's column (a daemon without columns splits it to the
    /// right), then shown and selected.
    private static func openInNewColumn(_ url: URL, anchor: PaneModel, context: AppActionContext) async throws {
        let handle = anchor.handle
        let connection = try context.requireConnection()
        guard case let browserTabs = context.services.cache.browserTabs,
              case .open(let choice) = browserTabs.resolve(requested: nil, url: url) else {
            throw ActionWorkFailure(MiscHandlerStrings.noBrowser)
        }
        let surface = try await browserTabs.open(choice, in: anchor, url: url.absoluteString, profile: nil)
        let width = context.services.newColumnWidth(nextTo: anchor)
        do {
            _ = try await connection.moveTabToColumn(surface, target: .pane(handle), afterColumn: nil, width: width)
        } catch DaemonError.missingCapabilities {
            try await connection.split(handle, direction: .right, movingTab: surface)
        }
        // The mirror reports the moved tab after the reply: show it once it does.
        await reveal(surface, context: context)
    }
}

/// `optchat/inspector.json`: where the local brain host serves the inspector.
nonisolated struct ChiefInspectorEndpoint: Decodable, Equatable, Sendable {
    let url: URL
    let token: String
    /// The host process; a file whose host has exited is stale (its port may
    /// belong to another program now, so its token is never sent there).
    let pid: Int32?

    /// No usable `inspector.json`: no local Chief host, or one without an inspector.
    struct Missing: Error {}

    /// Whether a local host wrote its file (blocking: off the main actor).
    nonisolated static func exists(muxHome: URL) -> Bool {
        (try? read(muxHome: muxHome)) != nil
    }

    /// Reads the file the running host wrote; refuses when there is none
    /// (no local Chief host, or one that serves no inspector). Blocking file
    /// I/O: callers run it off the main actor.
    nonisolated static func read(muxHome: URL) throws -> ChiefInspectorEndpoint {
        let file = muxHome.appendingPathComponent("optchat/inspector.json")
        // concurrency-allow: nonisolated; the action reads it in Task.detached (bind above)
        guard let data = try? Data(contentsOf: file),
              let endpoint = try? JSONDecoder().decode(ChiefInspectorEndpoint.self, from: data),
              endpoint.url.host == "127.0.0.1",
              endpoint.pid.map(Self.isRunning) ?? true else {
            throw Missing()
        }
        return endpoint
    }

    nonisolated static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// The page's URL with a fresh one-time ticket (`GET /api/ticket` with the token).
    func ticketURL(session: URLSession = .shared) async throws -> URL {
        var request = URLRequest(url: url.appendingPathComponent("api/ticket"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        let ticket = try JSONDecoder().decode(Ticket.self, from: data).ticket
        return Self.pageURL(base: url, ticket: ticket)
    }

    static func pageURL(base: URL, ticket: String) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.path = "/"
        parts.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        return parts.url ?? base
    }

    private struct Ticket: Decodable { let ticket: String }
}

enum ChiefInspectorStrings {
    static var pageTitle: String {
        String(localized: "handlers.chief.inspector.pageTitle", defaultValue: "Chief Memory", table: "MiscHandlers", bundle: .module)
    }
    static var serverOffline: String {
        String(localized: "handlers.chief.inspector.serverOffline",
               defaultValue: "The server with this Chief is not connected.", table: "MiscHandlers", bundle: .module)
    }
    static var noLocalChief: String {
        String(localized: "handlers.chief.inspector.noLocalChief",
               defaultValue: "The Memory Inspector shows a Chief that runs on this Mac. Start the Chief (send it a message in Home), then try again.",
               table: "MiscHandlers", bundle: .module)
    }
    static var unreachable: String {
        String(localized: "handlers.chief.inspector.unreachable",
               defaultValue: "The Chief's Memory Inspector did not answer. Restart cmux to restart the Chief, then try again.",
               table: "MiscHandlers", bundle: .module)
    }
}
