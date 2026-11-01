import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextHomeEngine
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
    /// admits this page's origin (`DaemonService.pageOrigins`). A video attachment plays from the
    /// daemon's own listener (`GET /attachments/<token>`, ws-attachments-v1); images come as data URLs.
    static let homeChannels = PageDescriptor(
        id: "cmux.home-channels", resource: "home-channels", namespaces: ["cmux.host.credential.", ChiefProfilePageRoute.prefix, ChiefBackendPageRoute.prefix, HomeSwitchPageRoute.prefix],
        nativeOps: [PageNativeOp.edit], commands: PageNativeOp.commands.union([PageSelectionMenu.quoteCommand]),
        csp: PageCSP(connect: ["ws://127.0.0.1:*"], media: ["http://127.0.0.1:*"]), acceptsFirstMouse: true) // Archive and message delete confirm in the page
}

extension PageFactory {
    /// The channels page's engine options.
    static let homeChannelsEngineOptions = PageEngineOptions.standard

    /// `cmux.app.edit {command}` on the Channels page: its route, and the provider whose `run` the page sets once its view exists.
    static func homeChannelsEditRoute() -> (route: PageRoute, edits: PageEditProvider) {
        let edits = PageEditProvider()
        return (PageRoute(prefix: PageNativeOp.edit, provider: edits), edits)
    }

    /// The React channels Home (a tab next to the native Home, or the docked Home's Channels view:
    /// only there `cmux.host.home.switchView` answers).
    func homeChannelsWebPage(dock: HomeDockView? = nil) -> PageWebView? {
        let provider = DaemonCredentialPageProvider(daemon: services.daemon, chief: services.home.chief)
        let (editRoute, edits) = Self.homeChannelsEditRoute()
        var routes = [PageRoute(prefix: "cmux.host.credential.", provider: provider),
                      PageRoute(prefix: ChiefProfilePageRoute.prefix, provider: ChiefProfilePageRoute(owner: services.home.chief)),
                      PageRoute(prefix: ChiefBackendPageRoute.prefix, provider: ChiefBackendPageRoute(center: services.agentHarnesses)),
                      editRoute]
        if let dock { routes.append(PageRoute(prefix: HomeSwitchPageRoute.prefix, provider: HomeSwitchPageRoute(dock: dock))) }
        guard let page = PageWebView(descriptor: .homeChannels, routes: routes,
                                     options: Self.homeChannelsEngineOptions, surface: .home) else { return nil }
        // The composers' right-click Cut, Copy and Paste run as the page view's own edits.
        edits.run = { [weak page] command in
            page?.performEdit(command.selector)
        }
        // Selected message text: Copy, Quote in Reply, Search the Web and Look Up, not Copy alone.
        let registry = services.registry
        page.contextMenuEditor = { [weak page] menu in
            PageSelectionMenu(
                quote: { page?.send(command: PageSelectionMenu.quoteCommand) },
                search: {
                    // task-owner: one selection read per menu choice; ends with the page's answer
                    Task { @MainActor in
                        guard let text = await page?.selectedText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        _ = registry.perform("browser.selection.search", invocation: ActionInvocation(arguments: ["text": .string(text)], origin: .user))
                    }
                }).rebuild(menu)
        }
        services.home.homeDidOpen(asked: true)
        return page
    }
}

/// Serves ``PageNativeOp/edit`` for a page with its own text-field menu. Each key or click backs one
/// edit: page script inside the gesture's second cannot paste again on a click the menu already used.
@MainActor
final class PageEditProvider: PageProvider {
    /// Runs the command on the page view, set once the view exists.
    var run: (@MainActor (AgentPaneEditCommand) -> Void)?
    private var spentGesture: TimeInterval?

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard op == PageNativeOp.edit else { throw PageError.unknownOp(op) }
        guard let command = params["command"]?.stringValue.flatMap(AgentPaneEditCommand.init(rawValue:)) else {
            throw PageError.invalidParams("command must be cut, copy, paste or pasteAsPlainText")
        }
        guard context.userGesture, let event = context.gestureEvent, event != spentGesture else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
        }
        spentGesture = event
        run?(command)
        return .null
    }
}

/// The host verb `cmux.host.credential.load`: the local daemon's WebSocket endpoint and its
/// credential, read from the daemon's own 0600 file next to its socket
/// (`<socket>.websocket.json`), plus `owner`: this build's Chief conversations (`ChiefOwnerPageEndpoint`).
/// Read again on every call (a reconnect gets new ports and credentials), only for the page that asked.
@MainActor
final class DaemonCredentialPageProvider: PageProvider {
    private weak var daemon: DaemonService?
    private weak var chief: ChiefConversationOwner?

    init(daemon: DaemonService, chief: ChiefConversationOwner?) {
        self.daemon = daemon
        self.chief = chief
    }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard op == "cmux.host.credential.load" else { throw PageError.unknownOp(op) }
        let credential = try await daemonCredential()
        guard case .object(var fields) = credential, let chief else { return credential }
        switch await chief.pageEndpoint(page: "home-channels") {
        case .starting: throw PageError.unavailable(Self.chiefStarting)
        case .unavailable: return credential
        case .ready(let owner):
            fields["owner"] = .object(["url": .string(owner.url), "token": .string(owner.token)])
            return .object(fields)
        }
    }

    private func daemonCredential() async throws -> CmuxNextSettings.JSONValue {
        guard let daemon, let endpoint = try? await daemon.endpoint() else {
            throw PageError.unavailable("the local cmux daemon is not running")
        }
        let path = endpoint.socketPath + ".websocket.json"
        let file = try await fileCredential(daemon, path: path)
        // The file names the endpoint. The page authenticates with a page credential when the
        // daemon has them: only that one carries the person's Cloud lease (the file token is any
        // same-user process's). An older daemon keeps the file token: local conversations only.
        guard daemon.supports(DaemonCapability.pageCredential.rawValue), case .object(var fields) = file else { return file }
        // A single-use credential for this connect (every reconnect asks again). A lost connection
        // retries. A refusal (a daemon this app did not start, so the app is not verified there)
        // keeps the file token: local conversations only, never a dead end.
        guard let connection = daemon.connection else { throw PageError.unavailable("the local cmux daemon is restarting") }
        do {
            let page = try await connection.request(PageCredentialRequest())
            fields["token"] = .string(page.credential)
            return .object(fields)
        } catch let error as DaemonError where error.isLostConnection {
            throw PageError.unavailable("the local cmux daemon is restarting")
        } catch {
            return file
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
        } catch let error as DaemonError where error.isLostConnection {
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

    static var chiefStarting: String {
        String(localized: "homeChannels.chief.starting", defaultValue: "Starting this build's Chief…", table: "Handlers", bundle: .module)
    }

    static var tooOld: String {
        String(localized: "homeChannels.daemon.tooOld",
               defaultValue: "This cmux daemon is too old to serve this page, and cmux cannot restart it. Update the cmux-tui binary that cmux uses, then open this tab again.",
               table: "Handlers", bundle: .module)
    }

    /// The listener's credential file (`PageListenerCredentialFile`): this user's, 0600, a live daemon.
    nonisolated static func read(_ path: String) throws -> CmuxNextSettings.JSONValue {
        guard let file = PageListenerCredentialFile.read(path) else {
            throw PageError.unavailable("This cmux daemon has no page listener. Quit cmux and its daemon, then open cmux again.")
        }
        return .object(["url": .string(file.url), "token": .string(file.token), "pages": .string(file.pages)])
    }
}
