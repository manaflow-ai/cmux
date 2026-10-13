import AppKit
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextPages
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

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == "cmux.host.credential.load" else { throw PageError.unknownOp(op) }
        guard let daemon, let endpoint = try? await daemon.endpoint() else {
            throw PageError.unavailable("the local cmux daemon is not running")
        }
        let path = endpoint.socketPath + ".websocket.json"
        return try await Task.detached(priority: .userInitiated) { try Self.read(path) }.value
    }

    nonisolated static func read(_ path: String) throws -> JSONValue {
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(CredentialFile.self, from: data),
              file.url.hasPrefix("ws://127.0.0.1:") || file.url.hasPrefix("ws://[::1]:")
        else { throw PageError.unavailable("the daemon has no WebSocket listener; restart cmux to open one") }
        return .object(["url": .string(file.url), "token": .string(file.token), "pages": .string(file.pages)])
    }

    private struct CredentialFile: Decodable {
        var url: String
        var pages: String
        var token: String
    }
}
