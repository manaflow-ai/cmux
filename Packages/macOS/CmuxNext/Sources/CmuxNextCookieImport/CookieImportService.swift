import AppKit
public import CmuxNextActions
import CmuxNextBrowserImport
import CmuxNextDesign
import CmuxNextWakeups
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
///
/// The run is one ``ActionCompletion``: the browser lookup and the import run off main, and each main-thread step
/// (the panel, the answer, the end) is one task in the run's class (user-blocking for a person's run, automation
/// for an agent's or the CLI's), as Chromium replies to off-thread work with a posted UI task
/// (`base::ThreadPool::PostTaskAndReplyWithResult`, base/task/thread_pool.h).
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
        let completion = ActionCompletion(on: host.deadlines.work)
        let destination = host.destination
        let run = CookieImportRun(query: query, filter: filter, reason: reason, targetID: target.id, targetName: target.name,
                                  requester: requester)
        host.track(completion.start { [weak self] in
            await Self.importCookies(run, into: destination, completion: completion, service: self)
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

    /// One run's import, off main. Nothing of the other browser is read before the person's Allow.
    nonisolated private static func importCookies(_ run: CookieImportRun, into destination: any CookieDestination,
                                                  completion: ActionCompletion, service: CookieImportService?) async -> ActionWorkFailure? {
        // Finding the browsers reads only folder names and Local State profile names (no cookie file).
        let sources = BrowserSourceDetector(environment: ImportEnvironment.live()).detect()
        let profile: BrowserSourceProfile
        do {
            profile = try run.query.resolve(in: sources)
        } catch {
            return await completion.apply(owner: "CookieImportService.unresolved", answering: true) { ActionWorkFailure(Self.message(for: error)) }
        }
        if let requester = run.requester {
            let answer = FirstOutcome<CookieImportAnswer>()
            let refusal = await completion.apply(owner: "CookieImportService.ask") { () -> ActionWorkFailure? in
                guard let service else { return ActionWorkFailure(CookieImportStrings.noWindow) }
                return service.ask(requester, run: run, profile: profile, answer: answer)
            }
            if let refusal { return refusal }
            let answered = await answer.value()
            let denied = await completion.apply(owner: "CookieImportService.answered") { () -> ActionWorkFailure? in
                service?.asking = nil
                switch answered {
                case .allow: return nil
                case .deny: return ActionWorkFailure(refusal: .unavailable, reason: CookieImportStrings.denied)
                case .timedOut: return ActionWorkFailure(refusal: .unavailable, reason: CookieImportStrings.timedOut)
                }
            }
            if let denied { return denied }
        }
        let importer = CookieImporter(destination: destination, keys: OneReadSafeStorage(SafeStorageKeys().live()))
        let report: CookieImportReport
        do {
            report = try await importer.run(profile, into: run.targetID, filter: run.filter)
        } catch let error as CookieImportError {
            return await completion.apply(owner: "CookieImportService.failed", answering: true) {
                ActionWorkFailure(CookieImportStrings.failed(Self.describe(error)))
            }
        } catch {
            // The type only: an error's text could hold a path or a cookie row.
            let kind = String(describing: type(of: error))
            return await completion.apply(owner: "CookieImportService.failed", answering: true) { ActionWorkFailure(CookieImportStrings.failed(kind)) }
        }
        let keepsAll = run.filter.keepsAll
        return await completion.apply(owner: "CookieImportService.done", answering: true) { () -> ActionWorkFailure? in
            if report.written == 0 && report.rejected == 0 && !keepsAll { return ActionWorkFailure(CookieImportStrings.nothingMatched) }
            if let window = service?.host.window() {
                let message = CookieImportStrings.done(count: report.written, browser: Self.sourceName(profile))
                _ = CmuxToastCenter.shared.show(CmuxToast(id: "cookieImport", message: message), in: window)
            }
            return nil
        }
    }

    /// Shows the consent panel for `run` in the host's window; the person's answer resolves `answer`. Returns why it
    /// did not show (a panel is already up, or cmux has no window).
    private func ask(_ requester: CookieImportRequester, run: CookieImportRun, profile: BrowserSourceProfile,
                     answer: FirstOutcome<CookieImportAnswer>) -> ActionWorkFailure? {
        guard asking == nil else { return ActionWorkFailure(CookieImportStrings.busy) }
        guard let window = host.window() else { return ActionWorkFailure(CookieImportStrings.noWindow) }
        let request = CookieImportRequest(requester: requester, reason: run.reason, source: Self.sourceName(profile),
                                          sourceIsSafari: profile.browser.family == .safari, domains: run.filter.domains,
                                          target: run.targetName)
        let reveal = host.reveal
        let panel = CookieImportConsentPanel(request: request, deadlines: host.deadlines, answer: answer,
                                             onShowRequester: requester.tabID.map { tab in { reveal(tab) } })
        asking = panel
        panel.show(on: window)
        return nil
    }

    nonisolated static func sourceName(_ profile: BrowserSourceProfile) -> String {
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

/// What one run imports: the source, the sites, the agent's reason, the target profile and who asked.
private nonisolated struct CookieImportRun: Sendable {
    let query: CookieSourceQuery
    let filter: CookieDomainFilter
    let reason: String
    let targetID: String
    let targetName: String
    let requester: CookieImportRequester?
}
