import AppKit
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextPages
import CmuxNextSettings
import Foundation

extension InternalPageID {
    static let homeChannels = InternalPageID(rawValue: "home-channels")
}

extension PageDescriptor {
    /// The channels Home (webviews/src/pages/home-channels): a client of this instance's daemon over
    /// its loopback WebSocket, the same protocol a plain browser uses (cmux-tui spec/transports.md
    /// "App listener and page files"). No Swift serves Home data; the host only hands the page the
    /// endpoint and the daemon's credential (`cmux.host.credential.load`, a host verb). The daemon
    /// admits this page's origin (`DaemonService.pageOrigin`).
    static let homeChannels = PageDescriptor(
        id: "cmux.home-channels", resource: "home-channels", namespaces: ["cmux.host.credential."],
        csp: PageCSP(connect: ["ws://127.0.0.1:*"]))
}

extension PageFactory {
    /// The React channels Home (a tab next to the native Home).
    func homeChannelsWebPage() -> PageWebView? {
        let provider = DaemonCredentialPageProvider(daemon: services.daemon)
        let routes = [PageRoute(prefix: "cmux.host.credential.", provider: provider)]
        guard let page = PageWebView(descriptor: .homeChannels, routes: routes, surface: .home) else { return nil }
        services.home.homeDidOpen()
        return page
    }
}

/// The host verb `cmux.host.credential.load`: the local daemon's WebSocket endpoint and its
/// credential, read from the daemon's own 0600 file next to its socket
/// (`<socket>.websocket.json`). Read again on every call, so a page reconnecting after a daemon
/// restart gets the new port and credential. The token goes only to the page that asked.
@MainActor
final class DaemonCredentialPageProvider: PageProvider {
    private weak var daemon: DaemonService?

    init(daemon: DaemonService) {
        self.daemon = daemon
    }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard op == "cmux.host.credential.load" else { throw PageError.unknownOp(op) }
        guard let daemon, let endpoint = try? await daemon.endpoint() else {
            throw PageError.unavailable("the local cmux daemon is not running")
        }
        let path = endpoint.socketPath + ".websocket.json"
        let file = try await fileCredential(daemon, path: path)
        // The file names the endpoint. The page authenticates with a page credential when the
        // daemon has them: only that one carries the person's Cloud lease (the file token is any
        // same-user process's). An older daemon keeps the file token: local conversations only.
        guard daemon.supports(DaemonCapabilities.shared.pageCredential), case .object(var fields) = file else { return file }
        // A single-use credential for this connect (every reconnect asks again). A lost connection
        // retries. A refusal (a daemon this app did not start, so the app is not verified there)
        // keeps the file token: local conversations only, never a dead end.
        guard let connection = daemon.connection else { throw PageError.unavailable("the local cmux daemon is restarting") }
        do {
            let page = try await connection.request(PageCredentialRequest())
            fields["token"] = .string(page.credential)
            return .object(fields)
        } catch let error as DaemonError where Self.isTransport(error) {
            throw PageError.unavailable("the local cmux daemon is restarting")
        } catch {
            return file
        }
    }

    /// A lost or restarting connection (retry), as opposed to the daemon's own refusal.
    nonisolated static func isTransport(_ error: DaemonError) -> Bool {
        switch error {
        case .notConnected, .connectionClosed, .daemonShutdown, .connectFailed, .timedOut: true
        default: false
        }
    }

    /// The credential file; when it is missing (an owner the CLI or an agent started, or an older
    /// build), the owner opens its listener (`ws-listen`), or an owner too old for that is handed
    /// off to the bundled build. Never a dead end.
    private func fileCredential(_ daemon: DaemonService, path: String) async throws -> CmuxNextSettings.JSONValue {
        // task-owner: one small file read off the main actor per call; ends with the read.
        if let file = try? await Task.detached(priority: .userInitiated, operation: { try Self.read(path) }).value {
            return file
        }
        let outcome: DaemonService.PageListenerOutcome
        do {
            outcome = try await daemon.ensurePageListener()
        } catch let error as DaemonError where Self.isTransport(error) {
            throw PageError.unavailable("the local cmux daemon is restarting")
        } catch DaemonError.command(_, let message, _, _, _) where message.contains("shutting down") {
            throw PageError.unavailable("the local cmux daemon is restarting")
        } catch DaemonError.command(_, let message, _, _, _) {
            // The daemon refused (a configured credential, an origin its listener does not admit):
            // final, the page says why.
            throw PageError(code: "cmux.daemon.page_listener", message: message, retryable: false)
        } catch {
            throw PageError.unavailable(String(describing: error))
        }
        switch outcome {
        case .ready:
            // task-owner: one small file read off the main actor; ends with the read.
            return try await Task.detached(priority: .userInitiated) { try Self.read(path) }.value
        case .restarting:
            // The page retries with backoff; the bundled build's owner starts with the listener.
            throw PageError.unavailable(Self.restarting)
        case .unsupported:
            throw PageError(code: "cmux.daemon.too_old", message: Self.tooOld, retryable: false)
        }
    }

    static var restarting: String {
        String(localized: "homeChannels.daemon.restarting", defaultValue: "Restarting the cmux daemon…", table: "Handlers", bundle: .module)
    }

    static var tooOld: String {
        String(localized: "homeChannels.daemon.tooOld",
               defaultValue: "This cmux daemon is too old to serve this page, and cmux cannot restart it. Update the cmux-tui binary that cmux uses, then open this tab again.",
               table: "Handlers", bundle: .module)
    }

    /// The file must be this user's, mode 0600, and name a live daemon: a stale file (a killed
    /// daemon) or one another user planted must never send the token to whatever owns that port.
    nonisolated static func read(_ path: String) throws -> CmuxNextSettings.JSONValue {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard (attributes?[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes?[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(CredentialFile.self, from: data),
              file.pid > 0, kill(file.pid, 0) == 0,
              file.url.hasPrefix("ws://127.0.0.1:") || file.url.hasPrefix("ws://[::1]:")
        else { throw PageError.unavailable("This cmux daemon has no page listener. Quit cmux and its daemon, then open cmux again.") }
        return .object(["url": .string(file.url), "token": .string(file.token), "pages": .string(file.pages)])
    }

    nonisolated private struct CredentialFile: Decodable {
        var pid: Int32
        var url: String
        var pages: String
        var token: String
    }
}
