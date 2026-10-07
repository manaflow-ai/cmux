import AppKit
import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// "Chief: Open Memory Inspector" (DEV and nightly, palette; the Chief
/// settings sidebar's Show Memory runs it too): the local Chief's brain host
/// serves a read-only memory inspector on 127.0.0.1 (optchat-chief
/// inspect/http.rs) and writes its address and token to
/// `<mux home>/optchat/inspector.json`. The app trades the token for a
/// one-time ticket and opens the page as a browser tab in a new column to
/// the right of the focused pane's column, so no live secret is ever in a URL.
@MainActor
enum ChiefInspectorHandlers {
    static let actionID: ActionID = "chief.openMemoryInspector"

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind(actionID, requires: DaemonCapabilities.shared.frontendBrowserTabs, daemon: context.daemon, run: { invocation in
            let pane = try context.pane(invocation)
            let muxHome = HomeBrainHost.muxHome(tag: context.services.environment.tag)
            // task-owner: one file read, one ticket request and one tab open; ends
            // with them (a caller such as `cmux action run` waits and gets the failure).
            context.registry.track(Task { @MainActor in
                do {
                    let endpoint = try await Task.detached { try ChiefInspectorEndpoint.read(muxHome: muxHome) }.value
                    let url = try await endpoint.ticketURL()
                    try await openInNewColumn(url, from: pane, context: context)
                    return nil
                } catch {
                    let reason = error is ChiefInspectorEndpoint.Missing ? ChiefInspectorStrings.noLocalChief : ChiefInspectorStrings.unreachable
                    context.daemon.logger.error("memory inspector: \(String(describing: error), privacy: .public)")
                    context.registry.refuse(reason)
                    return ActionWorkFailure(reason)
                }
            })
        })
    }

    /// A new browser tab at `url` in `pane`, moved into a new column right
    /// of the pane's column; a daemon without columns splits it to the right.
    private static func openInNewColumn(_ url: URL, from pane: PaneController, context: AppActionContext) async throws {
        let handle = pane.pane.handle
        let connection = try context.requireConnection()
        guard let browserTabs = context.services.cache.browserTabs,
              case .open(let choice) = browserTabs.resolve(requested: nil) else { return }
        let surface = try await browserTabs.open(choice, in: handle, url: url.absoluteString, profile: nil)
        let spawn = context.services.newColumnWidth(nextTo: pane.pane)
        do {
            _ = try await connection.moveTabToColumn(surface, target: .pane(handle), afterColumn: nil, width: spawn.width)
            spawn.commit()
        } catch DaemonError.missingCapabilities {
            try await connection.split(handle, direction: .right, movingTab: surface)
        }
    }
}

/// `optchat/inspector.json`: where the local brain host serves the inspector.
nonisolated struct ChiefInspectorEndpoint: Decodable, Equatable, Sendable {
    let url: URL
    let token: String

    /// No usable `inspector.json`: no local Chief host, or one without an inspector.
    struct Missing: Error {}

    /// Reads the file the running host wrote; refuses when there is none
    /// (no local Chief host, or one that serves no inspector). Blocking file
    /// I/O: callers run it off the main actor.
    nonisolated static func read(muxHome: URL) throws -> ChiefInspectorEndpoint {
        let file = muxHome.appendingPathComponent("optchat/inspector.json")
        // concurrency-allow: nonisolated; the action reads it in Task.detached (bind above)
        guard let data = try? Data(contentsOf: file),
              let endpoint = try? JSONDecoder().decode(ChiefInspectorEndpoint.self, from: data),
              endpoint.url.host == "127.0.0.1" else {
            throw Missing()
        }
        return endpoint
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
