import AppKit
public import CmuxNextActions
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
public final class CookieImportService {
    private let host: CookieImportHost
    /// The panel waiting for the person; one at a time.
    private var asking: CookieImportConsentPanel?

    /// Creates the service over what the App supplies.
    public init(host: CookieImportHost) {
        self.host = host
    }

    /// Validates the run, then (in tracked work, so the CLI waits) asks the person when needed and imports.
    ///
    /// - Throws: `CookieImportRefusal` when `--from` is missing or malformed, an agent gave no reason, or a panel is already up.
    public func run(_ invocation: ActionInvocation) throws {
        guard let from = invocation["from"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !from.isEmpty else {
            throw CookieImportRefusal(message: CookieImportStrings.missingSource)
        }
        let query: CookieSourceQuery
        do { query = try CookieSourceQuery(from) } catch { throw CookieImportRefusal(message: CookieImportStrings.missingSource) }
        let filter = CookieDomainFilter(invocation["domain"]?.stringValue ?? "")
        let reason = invocation["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let asks = Self.needsConsent(invocation)
        if asks, Self.needsReason(invocation), reason.isEmpty { throw CookieImportRefusal(message: CookieImportStrings.reasonRequired) }
        if asks, asking != nil { throw CookieImportRefusal(message: CookieImportStrings.busy) }
        let target = host.target(invocation)
        let requester = asks ? host.requester(invocation) : nil
        host.track(Task { @MainActor [weak self] in
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

    private func importCookies(query: CookieSourceQuery, filter: CookieDomainFilter, reason: String, target: (id: String, name: String),
                               requester: CookieImportRequester?) async -> ActionWorkFailure? {
        // Finding the browsers reads only folder names and Local State profile names (no cookie file).
        let sources = await Task.detached {
            let environment = ImportEnvironment.live()
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
            guard let window = host.window() else { return ActionWorkFailure(CookieImportStrings.noWindow) }
            let request = CookieImportRequest(requester: requester, reason: reason, source: sourceName,
                                              sourceIsSafari: profile.browser.family == .safari, domains: filter.domains, target: target.name)
            let reveal = host.reveal
            let panel = CookieImportConsentPanel(request: request, onShowRequester: requester.tabID.map { tab in { reveal(tab) } })
            asking = panel
            let answer = await panel.ask(on: window)
            asking = nil
            switch answer {
            case .allow: break
            case .deny: return ActionWorkFailure(refusal: .unavailable, reason: CookieImportStrings.denied)
            case .timedOut: return ActionWorkFailure(refusal: .unavailable, reason: CookieImportStrings.timedOut)
            }
        }
        let importer = CookieImporter(destination: host.destination, keys: OneReadSafeStorage(SafeStorageKeys().live()))
        let report: CookieImportReport
        do {
            report = try await importer.run(profile, into: target.id, filter: filter)
        } catch let error as CookieImportError {
            return ActionWorkFailure(CookieImportStrings.failed(Self.describe(error)))
        } catch {
            // The type only: an error's text could hold a path or a cookie row.
            return ActionWorkFailure(CookieImportStrings.failed(String(describing: type(of: error))))
        }
        if report.written == 0 && report.rejected == 0 && !filter.keepsAll { return ActionWorkFailure(CookieImportStrings.nothingMatched) }
        if let window = host.window() {
            _ = CmuxToastCenter.shared.show(CmuxToast(id: "cookieImport", message: CookieImportStrings.done(count: report.written, browser: sourceName)),
                                            in: window)
        }
        return nil
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
