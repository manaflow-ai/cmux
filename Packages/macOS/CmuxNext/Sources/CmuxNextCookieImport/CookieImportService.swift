import AppKit
public import CmuxNextActions
public import CmuxNextBrowserImport
import CmuxNextDesign
import Foundation

/// Import Cookies from Browser (`browser.importCookies`, CLI
/// `cmux browser import-cookies --from <browser>[:<profile>] [--domain …] --reason "…"`):
/// one profile of another browser on this Mac (Chromium family, Safari,
/// Firefox family) into a cmux browser profile, optionally only some sites.
///
/// A person's run (palette) imports at once. Any other run (an agent's MCP tool, the CLI from a
/// script, an agent or a Home Chief) must give a reason, and the person first answers the
/// permission card (``CookieImportAsk``): inline in the chat where they talk to that agent (the
/// Home Chief's conversation, the agent's chat tab), else as a window card. Nothing of the other
/// browser is read before Allow Once. After it macOS asks for the browser's Keychain key
/// (Chromium) or cmux needs Full Disk Access (Safari); the card says so first.
///
/// Every request, whatever its outcome, gets one audit record in ``CookieImportHost/ledger``: who
/// asked, why, from where, into which profile, the answer, the counts and the written cookies'
/// names, domains and paths, so ``remove(_:)`` can take exactly those back out. Cookies stay in
/// memory between the reader and the target jar; no cookie value is logged, printed or recorded.
@MainActor
public final class CookieImportService {
    private let host: CookieImportHost
    /// The ask waiting for the person; one at a time.
    private var asking: CookieImportAsk?

    /// Creates the service over what the App supplies.
    public init(host: CookieImportHost) {
        self.host = host
    }

    /// Validates the run, then (in tracked work, so the CLI waits) asks the person when needed and imports.
    ///
    /// - Throws: `CookieImportRefusal` when `--from` is missing or malformed, a site is not a host
    ///   name, an agent gave no reason, or an ask is already up.
    public func run(_ invocation: ActionInvocation) throws {
        guard let from = invocation["from"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !from.isEmpty else {
            throw CookieImportRefusal(message: CookieImportStrings.missingSource)
        }
        let query: CookieSourceQuery
        do { query = try CookieSourceQuery(from) } catch { throw CookieImportRefusal(message: CookieImportStrings.missingSource) }
        let filter = try Self.filter(invocation["domain"]?.stringValue ?? "")
        let reason = CookieImportText().shown(invocation["reason"]?.stringValue ?? "")
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
    /// agent session) may leave it out; the card still asks them.
    nonisolated static func needsReason(_ invocation: ActionInvocation) -> Bool {
        invocation.origin != .user && !(invocation.origin == .cli && invocation.callerAgentSession == nil && !invocation.callerHomeChat)
    }

    /// The `--domain` list as the card shows it and the import keeps it: each site in ASCII. A
    /// value that is not a host name refuses the run, so the card never shows less than is read.
    static func filter(_ list: String) throws -> CookieDomainFilter {
        let text = CookieImportText()
        let raw = CookieDomainFilter(list).domains
        var sites: [String] = []
        for domain in raw {
            guard let site = text.site(domain) else { throw CookieImportRefusal(message: CookieImportStrings.invalidSite(text.shown(domain, limit: 60))) }
            sites.append(site)
        }
        return CookieDomainFilter(sites)
    }

    /// The ask on screen now, nil when none (Debug and tests).
    public var currentAsk: CookieImportAsk? { asking }

    private func importCookies(query: CookieSourceQuery, filter: CookieDomainFilter, reason: String, target: (id: String, name: String),
                               requester: CookieImportRequester?) async -> ActionWorkFailure? {
        // Finding the browsers reads only folder names and Local State profile names (no cookie file).
        let sources = await host.sources()
        let profile: BrowserSourceProfile
        do {
            profile = try query.resolve(in: sources)
        } catch {
            return ActionWorkFailure(Self.message(for: error))
        }
        let sourceName = Self.sourceName(profile)
        let audit = Audit(requester: requester, reason: reason, source: sourceName, target: target, sites: filter.domains)
        var ask: CookieImportAsk?
        if let requester {
            guard asking == nil else { return ActionWorkFailure(CookieImportStrings.busy) }
            let request = CookieImportRequest(requester: requester, reason: reason, source: sourceName, prompt: Self.prompt(profile.browser),
                                              domains: filter.domains, target: target.name)
            let shown = CookieImportAsk(request: request, armDelay: host.armDelay)
            let reveal = host.reveal
            if let tab = requester.tabID { shown.onShowRequester = { reveal(tab) } }
            shown.onShowAll = host.showAll
            if !host.presentInline(shown) {
                guard let window = host.window() else {
                    await record(audit, .failed, failure: CookieImportStrings.noWindow)
                    return ActionWorkFailure(CookieImportStrings.noWindow)
                }
                CookieImportConsentPanel(ask: shown).show(on: window)
            }
            asking = shown
            ask = shown
            shown.shown()
            let answer = await shown.nextAnswer()
            asking = nil
            switch answer {
            case .allow: break
            case .deny:
                // The person's own Deny needs no "nothing was imported" card after it: it goes away.
                shown.end(CookieImportStrings.denied)
                shown.dismiss()
                await record(audit, .denied)
                return ActionWorkFailure(refusal: .unavailable, reason: CookieImportStrings.denied)
            case .timedOut:
                shown.end(CookieImportStrings.timedOut)
                await record(audit, .timedOut)
                return ActionWorkFailure(refusal: .unavailable, reason: CookieImportStrings.timedOut)
            }
        }
        let importer = CookieImporter(destination: host.destination, keys: host.keys())
        let report: CookieImportReport
        let cookies: [ImportedCookieIdentity]
        do {
            let result = try await importer.runListing(profile, into: target.id, filter: filter)
            report = result.report
            cookies = result.cookies
        } catch {
            // A typed import error by its words; anything else by its type only: its text could hold a path or a cookie row.
            let detail = (error as? CookieImportError).map(Self.describe) ?? String(describing: type(of: error))
            let text = CookieImportStrings.failed(detail)
            ask?.end(text)
            await record(audit, .failed, failure: text)
            return ActionWorkFailure(text)
        }
        if report.written == 0 && report.rejected == 0 && !filter.keepsAll {
            ask?.end(CookieImportStrings.nothingMatched)
            await record(audit, .nothingMatched, report: report)
            return ActionWorkFailure(CookieImportStrings.nothingMatched)
        }
        let saved = await record(audit, .imported, report: report, cookies: cookies)
        if let ask {
            ask.phase = .imported(saved)
            ask.onRemove = { [weak self, weak ask] in
                guard let self else { return }
                Task { @MainActor in  // task-owner: one removal the person pressed; the card shows its end
                    if let removed = try? await self.remove(saved.id) { ask?.phase = .removed(removed) }
                }
            }
        } else if let window = host.window() {
            _ = CmuxToastCenter.shared.show(CmuxToast(id: "cookieImport", message: CookieImportStrings.done(count: report.written, browser: sourceName)),
                                            in: window)
        }
        return nil
    }

    /// Takes the cookies import `id` wrote back out of its cmux profile and marks the record removed.
    ///
    /// - Returns: The updated record.
    /// - Throws: `CookieImportRefusal` when the ledger has no such import, or it has nothing left to remove.
    @discardableResult
    public func remove(_ id: String) async throws -> CookieImportRecord {
        guard let record = await host.ledger.record(id) else { throw CookieImportRefusal(message: CookieImportStrings.unknownImport) }
        guard record.canRemove else { throw CookieImportRefusal(message: CookieImportStrings.alreadyRemoved) }
        let removed = try await host.destination.removeCookies(record.cookies, profileID: record.targetProfileID)
        let marked = await host.ledger.markRemoved(id, at: Date()) ?? record
        if let window = host.window() {
            _ = CmuxToastCenter.shared.show(CmuxToast(id: "cookieImportRemoved", message: CookieImportStrings.removedToast(removed)), in: window)
        }
        return marked
    }

    /// The facts of one request the audit record keeps.
    private struct Audit {
        var requester: CookieImportRequester?
        var reason: String
        var source: String
        var target: (id: String, name: String)
        var sites: [String]
    }

    @discardableResult
    private func record(_ audit: Audit, _ outcome: CookieImportRecord.Outcome, failure: String? = nil, report: CookieImportReport? = nil,
                        cookies: [ImportedCookieIdentity] = []) async -> CookieImportRecord {
        let who = audit.requester.map { CookieImportRecord.Requester(kind: Self.kindName($0.kind), name: $0.name) }
            ?? CookieImportRecord.Requester(kind: "person", name: "")
        let record = CookieImportRecord(date: Date(), requester: who, reason: audit.reason, source: audit.source,
                                        targetProfileID: audit.target.id, targetProfileName: audit.target.name, requestedSites: audit.sites,
                                        outcome: outcome, failure: failure, report: report, cookies: cookies)
        await host.ledger.append(record)
        return record
    }

    static func kindName(_ kind: CookieImportRequester.Kind) -> String {
        switch kind {
        case .agentChat: "agentChat"
        case .homeChief: "homeChief"
        case .terminal: "terminal"
        case .unknown: "unknown"
        }
    }

    /// What macOS asks after Allow for `browser`.
    static func prompt(_ browser: ImportBrowser) -> CookieImportRequest.Prompt {
        switch browser.family {
        case .chromium: browser.safeStorageService.map { .keychain(service: $0) } ?? .none
        case .safari: .fullDiskAccess
        default: .none
        }
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
