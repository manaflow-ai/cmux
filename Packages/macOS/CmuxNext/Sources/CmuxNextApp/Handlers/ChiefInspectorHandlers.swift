import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Observation

/// "Chief: Open Memory Inspector" (DEV and nightly, palette; the Chief
/// settings sidebar's Show Memory runs it too): the local Chief's brain host
/// serves a read-only memory inspector on 127.0.0.1 (optchat-chief
/// inspect/http.rs) and writes its address and token to
/// `<mux home>/optchat/inspector.json`. The app trades the token for a
/// one-time ticket and opens the page as a browser tab in a new column to
/// the right of the focused pane's column, so no live secret is ever in a URL.
/// From Home (no focused pane) the column goes right of the window's
/// workspace's last column, and the app shows that workspace.
@MainActor
enum ChiefInspectorHandlers {
    static let actionID: ActionID = "chief.openMemoryInspector"

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let remotePage = ChiefInspectorPageService(services: context.services)
        context.services.pages.register(remotePage)
        registry.bind(actionID, requires: DaemonCapabilities.shared.frontendBrowserTabs, daemon: context.daemon, run: { invocation in
            let anchor = try anchorPane(invocation, context: context)
            let muxHome = HomeBrainHost.muxHome(tag: context.services.environment.tag)
            // task-owner: one file read, one ticket request and one tab open; ends
            // with them (a caller such as `cmux action run` waits and gets the failure).
            context.registry.track(Task { @MainActor in
                do {
                    // No Chief on this Mac: a paired server's Chief, through its daemon.
                    if !(await Task.detached { ChiefInspectorEndpoint.exists(muxHome: muxHome) }.value),
                       let server = remoteChief(context) {
                        try openRemote(server, page: remotePage, anchor: anchor, invocation: invocation, context: context)
                        return nil
                    }
                    let endpoint = try await Task.detached { try ChiefInspectorEndpoint.read(muxHome: muxHome) }.value
                    let url = try await endpoint.ticketURL()
                    try await openInNewColumn(url, anchor: anchor, context: context)
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
        })
    }

    /// A connected paired server whose brain daemon serves `chief-inspect`.
    private static func remoteChief(_ context: AppActionContext) -> ServerMachineSession? {
        context.services.machines.servers.first { $0.daemon.supports(DaemonCapabilities.shared.chiefInspect) }
    }

    /// The remote inspector page in this window, then moved into a new
    /// column right of `anchor`'s column.
    private static func openRemote(_ server: ServerMachineSession, page: ChiefInspectorPageService, anchor: PaneModel,
                                   invocation: ActionInvocation, context: AppActionContext) throws {
        guard let window = context.services.windows.active,
              page.open(machineID: server.machineID, in: window, focus: invocation.allowsViewChange) else {
            throw ActionWorkFailure(RefusalStrings.noWindowOpen)
        }
        if let located = context.allTabs.first(where: { $0.tab.page == InternalPageID.chiefInspector.rawValue }),
           located.pane.id != anchor.id || located.pane.tabs.count > 1 {
            TabMoves.toNewColumn(located.tab, anchor: anchor, services: context.services)
        }
    }

    /// The pane the new column goes right of: the focused (or targeted) pane;
    /// with none (Home is shown), the last pane of the window's workspace
    /// unless that is the home workspace, else of the first user workspace.
    private static func anchorPane(_ invocation: ActionInvocation, context: AppActionContext) throws -> PaneModel {
        let scope = context.scope(invocation)
        if let pane = scope.pane { return pane.pane }
        guard invocation.target == nil else { throw ActionFailure(message: MiscHandlerStrings.noPane) }
        // The home workspace (kind "home") holds only the Chief conversation
        // that the Home page shows: the column goes into a user workspace.
        let user = { (w: WorkspaceModel) in w.kind != "home" && w.screens.first?.panes.last != nil }
        let workspace = scope.workspace.flatMap { user($0) ? $0 : nil }
            ?? context.daemon.store.workspaces.first(where: user)
        guard let pane = workspace?.screens.first?.panes.last else { throw ActionFailure(message: MiscHandlerStrings.noPane) }
        return pane
    }

    /// A new browser tab at `url` in `anchor`, moved into a new column right
    /// of the anchor's column (a daemon without columns splits it to the
    /// right), then shown and selected.
    private static func openInNewColumn(_ url: URL, anchor: PaneModel, context: AppActionContext) async throws {
        let handle = anchor.handle
        let connection = try context.requireConnection()
        guard let browserTabs = context.services.cache.browserTabs,
              case .open(let choice) = browserTabs.resolve(requested: nil) else {
            throw ActionWorkFailure(MiscHandlerStrings.noBrowser)
        }
        let surface = try await browserTabs.open(choice, in: handle, url: url.absoluteString, profile: nil)
        let spawn = context.services.newColumnWidth(nextTo: anchor)
        do {
            _ = try await connection.moveTabToColumn(surface, target: .pane(handle), afterColumn: nil, width: spawn.width)
            spawn.commit()
        } catch DaemonError.missingCapabilities {
            try await connection.split(handle, direction: .right, movingTab: surface)
        }
        // The mirror reports the moved tab after the reply: show it once it does.
        let located = try? await ControlDeadline.shared.run(method: "chief-inspector.reveal", deadline: .now + .seconds(5)) { @MainActor in
            for await tab in Observations({ context.allTabs.first { $0.tab.surface == surface } }) {
                if let tab { return tab }
            }
            return nil as LocatedTab?
        }
        if let located = located ?? nil { context.reveal(located) }
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
