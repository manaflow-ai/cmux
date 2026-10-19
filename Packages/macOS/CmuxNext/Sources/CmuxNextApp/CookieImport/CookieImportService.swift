import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDesign
import Foundation

/// Import Cookies from Browser (`browser.importCookies`, CLI
/// `cmux browser import-cookies --from <browser>[:<profile>] [--domain …] --reason "…"`):
/// one profile of another browser on this Mac (Chromium family, Safari,
/// Firefox family) into a cmux browser profile, optionally only some sites.
///
/// A person's run (palette) imports at once. Any other run (an agent's MCP
/// tool, the CLI from a script or agent) must give a reason, and the person
/// first answers ``CookieImportConsentPanel``, which names the agent's chat or
/// terminal tab; nothing of the other browser is read before Allow. After
/// Allow macOS asks for the browser's Keychain key (Chromium) or cmux needs
/// Full Disk Access (Safari). Cookies stay in memory between the reader and
/// the target profile's Chromium jar; only counts leave the run, and no
/// cookie value is logged or printed.
@MainActor
final class CookieImportService {
    private unowned let services: AppServices
    /// The panel waiting for the person; one at a time.
    private var asking: CookieImportConsentPanel?

    init(services: AppServices) {
        self.services = services
    }

    /// Validates the run, then (in tracked work, so the CLI waits) asks the person when needed and imports.
    func run(_ invocation: ActionInvocation) throws {
        guard let from = invocation["from"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !from.isEmpty else {
            throw ActionFailure(message: CookieImportStrings.missingSource)
        }
        let query: CookieSourceQuery
        do { query = try CookieSourceQuery(from) } catch { throw ActionFailure(message: CookieImportStrings.missingSource) }
        let filter = CookieDomainFilter(invocation["domain"]?.stringValue ?? "")
        let reason = invocation["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let asks = Self.needsConsent(invocation)
        if asks, Self.needsReason(invocation), reason.isEmpty { throw ActionFailure(message: CookieImportStrings.reasonRequired) }
        if asks, asking != nil { throw ActionFailure(message: CookieImportStrings.busy) }
        let target = BookmarkResolver(services: services).profile(invocation)
        let requester = asks ? Self.requester(invocation, services: services) : nil
        services.registry.track(Task { @MainActor [weak self] in
            guard let self else { return nil }
            return await importCookies(query: query, filter: filter, reason: reason, target: target, requester: requester)
        })
    }

    /// Every run but a person's in this app asks first (an agent, a script, another client).
    nonisolated static func needsConsent(_ invocation: ActionInvocation) -> Bool {
        invocation.origin != .user
    }

    /// An agent must say why. A person typing the command at a terminal (`cli` origin with no
    /// agent session) may leave it out; the panel still asks them.
    nonisolated static func needsReason(_ invocation: ActionInvocation) -> Bool {
        invocation.origin != .user && !(invocation.origin == .cli && invocation.callerAgentSession == nil)
    }

    private func importCookies(query: CookieSourceQuery, filter: CookieDomainFilter, reason: String, target: String,
                               requester: CookieImportRequest.Requester?) async -> ActionWorkFailure? {
        // Finding the browsers reads only folder names and Local State profile names (no cookie file).
        let sources = await Task.detached {
            let environment = ImportEnvironment.live { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            return BrowserSourceDetector(environment: environment).detect()
        }.value
        let profile: BrowserSourceProfile
        do {
            profile = try query.resolve(in: sources)
        } catch {
            return ActionWorkFailure(Self.message(for: error))
        }
        let sourceName = Self.sourceName(profile)
        if let requester {
            guard asking == nil else { return ActionWorkFailure(CookieImportStrings.busy) }
            guard let window = services.windows.active?.window ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else {
                return ActionWorkFailure(CookieImportStrings.noWindow)
            }
            let request = CookieImportRequest(requester: requester, reason: reason, source: sourceName,
                                              sourceIsSafari: profile.browser.family == .safari, domains: filter.domains,
                                              target: services.browserProfiles.record(target)?.name ?? target)
            let panel = CookieImportConsentPanel(request: request, onShowRequester: requester.tabID.map { tab in
                { [weak self] in self?.reveal(tab: tab) }
            })
            asking = panel
            let answer = await panel.ask(on: window)
            asking = nil
            switch answer {
            case .allow: break
            case .deny: return ActionWorkFailure(refusal: .unavailable, reason: CookieImportStrings.denied)
            case .timedOut: return ActionWorkFailure(refusal: .unavailable, reason: CookieImportStrings.timedOut)
            }
        }
        let cef = services.cache.cef
        let importer = CookieImporter(destination: AppCookieDestination { writes, engineProfile in try await cef.importCookies(writes, into: engineProfile) },
                                      keys: OneReadSafeStorage(SafeStorageKeys().live()))
        let report: CookieImportReport
        do {
            report = try await importer.run(profile, into: target, filter: filter)
        } catch let error as CookieImportError {
            return ActionWorkFailure(CookieImportStrings.failed(Self.describe(error)))
        } catch {
            // The type only: an error's text could hold a path or a cookie row.
            return ActionWorkFailure(CookieImportStrings.failed(String(describing: type(of: error))))
        }
        if report.written == 0 && report.rejected == 0 && !filter.keepsAll { return ActionWorkFailure(CookieImportStrings.nothingMatched) }
        if let window = services.windows.active?.window {
            _ = CmuxToastCenter.shared.show(CmuxToast(id: "cookieImport", message: CookieImportStrings.done(count: report.written, browser: sourceName)),
                                            in: window)
        }
        return nil
    }

    /// The person's "Show Agent Chat": the requester's tab, focused as a person's click.
    private func reveal(tab: String) {
        _ = services.registry.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab), origin: .user))
    }

    /// Who asked: the agent chat (`caller.agent_session`), else the terminal (`caller.terminal_id`).
    static func requester(_ invocation: ActionInvocation, services: AppServices) -> CookieImportRequest.Requester {
        let panes = services.daemon.store.workspaces.flatMap { workspace in workspace.screens.flatMap(\.panes).map { (workspace, $0) } }
        if let session = invocation.callerAgentSession {
            let tabs = services.agentTabs
            for (workspace, pane) in panes {
                guard let tab = pane.tabs.first(where: { (tabs.sessions[tabs.resolve($0.id)] ?? $0.agentSession?.session) == session }) else { continue }
                let latest = services.chatsFeed?.chats.first { $0.sessionID == session }?.preview
                return .init(kind: .agentChat, name: tab.displayTitle, workspace: workspace.displayName, tabID: tab.id, latestMessage: latest)
            }
            let latest = services.chatsFeed?.chats.first { $0.sessionID == session }
            return .init(kind: .agentChat, name: latest?.title ?? session, workspace: nil, tabID: nil, latestMessage: latest?.preview)
        }
        if let terminal = invocation.callerTerminal {
            for (workspace, pane) in panes {
                guard let tab = pane.tabs.first(where: {
                    $0.terminalID?.rawValue == terminal || $0.terminalResourceID?.rawValue == terminal
                }) else { continue }
                return .init(kind: .terminal, name: tab.displayTitle, workspace: workspace.displayName, tabID: tab.id, latestMessage: nil)
            }
        }
        return .init(kind: .unknown, name: "", workspace: nil, tabID: nil, latestMessage: nil)
    }

    static func sourceName(_ profile: BrowserSourceProfile) -> String {
        let browser = profile.browser.displayName
        let single = profile.browser.family == .safari || profile.directoryName.isEmpty || profile.displayName.isEmpty
        return single ? browser : "\(browser) · \(profile.displayName)"
    }

    static func message(for error: CookieSourceQuery.Failure) -> String {
        switch error {
        case .empty: CookieImportStrings.missingSource
        case .unknownBrowser(let name, let known): CookieImportStrings.unknownBrowser(name, known: known)
        case .unknownProfile(let browser, let profile, let known): CookieImportStrings.unknownProfile(browser, profile, known: known)
        case .unsupported(let browser): CookieImportStrings.unsupported(browser)
        }
    }

    /// A cookie import error without values or paths.
    static func describe(_ error: CookieImportError) -> String {
        switch error {
        case .keyNotFound(let service): CookieImportStrings.keyNotFound(service)
        case .keychainDenied: CookieImportStrings.keychainDenied
        case .needsFullDiskAccess: CookieImportStrings.needsFullDiskAccess
        default: String(describing: error)
        }
    }
}
