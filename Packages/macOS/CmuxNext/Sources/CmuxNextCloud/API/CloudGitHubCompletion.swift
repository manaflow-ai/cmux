public import Foundation
import Observation

/// How many GitHub completions answered this launch (``CloudGitHubCompletion/handle(_:auth:)``), one per sign-in
/// (``CloudAuth/gitHubChanges``): Settings' GitHub and each chat's folder menu observe it and read GitHub again, so the
/// repositories list with no restart and no click.
///
/// It also keeps the last completion the API refused (``refusal``), so the Connect GitHub button can say why the link
/// did not take instead of staying silent.
@MainActor @Observable public final class CloudGitHubChanges {
    public internal(set) var count = 0
    /// The last completion's refusal (an expired state, a non-owner's request, GitHub refusing the code); nil when the
    /// last answer connected, none came back, or a new connect started. ``count`` changes after it is set.
    public internal(set) var refusal: Refusal?
    public init() {}

    /// Why a completion was refused: the API's `reason` when it gave words that are safe to show, else nil (the link
    /// expired is the common case, and the client's own words say it).
    public struct Refusal: Equatable, Sendable {
        public let reason: String?
        public init(reason: String?) { self.reason = reason }
    }

    /// Where the connect the app is running stands, for the app's own progress line and cards (Leo, 2026-11-25: "cant
    /// we own more of this end of the flow?"). Every change also counts in ``count``, so a picker reads it again.
    public internal(set) var phase: Phase = .idle

    /// One connect, from Connect to its end, as the app shows it.
    public enum Phase: Equatable, Sendable {
        case idle
        /// GitHub's page is open in the app's sheet; the person has not finished there.
        case onGitHub
        /// GitHub came back; the app is finishing the connection.
        case finishing
        /// Connected; `account` is the GitHub account's name when the API gave it.
        case connected(account: String?)
        /// The person asked an organization's owners to install the App (GitHub's `setup_action=request`): nothing to
        /// finish until an owner approves. `owner`: the organization, when the connect named a repository.
        case requested(owner: String?)
    }

    /// Records what a completion answered: a refusal is kept, a connection or a lost answer clears the last one.
    func record(_ answer: CloudOwnerAPIClient.GitHubCompletion, reason: String?, account: String? = nil) {
        switch answer {
        case .refused: refusal = Refusal(reason: reason); phase = .idle
        case .connected: refusal = nil; phase = .connected(account: account)
        // An owner's approval pending is not a refusal: the person is told it is pending.
        case .pendingApproval: refusal = nil; phase = .requested(owner: nil)
        case .noAnswer: refusal = nil; phase = .idle
        }
        count += 1
    }

    /// An organization's install request went to its owners (``Phase/requested(owner:)``): not a refusal.
    func recordRequested(owner: String?) {
        refusal = nil
        phase = .requested(owner: owner)
        count += 1
    }

    /// The app opened GitHub's page in its sheet (``Phase/onGitHub``).
    public func openedGitHub() {
        refusal = nil
        phase = .onGitHub
        count += 1
    }

    /// The sheet closed: still on GitHub means the person closed it before finishing, and the connect is back to idle.
    public func closedGitHub() {
        guard phase == .onGitHub else { return }
        phase = .idle
        count += 1
    }

    /// The person saved an installation's settings in the app's sheet (no state: nothing to finish). GitHub tells the API
    /// itself; the picker reads GitHub again now.
    public func savedOnGitHub() {
        refusal = nil
        phase = .connected(account: nil)
        count += 1
    }

    func finishing() {
        phase = .finishing
        count += 1
    }

    /// Records a connection that completed through an API request rather than GitHub's callback (a signed-out
    /// Connect replayed after sign-in). The picker uses this to wake pages waiting for the same change notification.
    public func recordConnected() {
        refusal = nil
        phase = .connected(account: nil)
        count += 1
    }

    /// A new Connect GitHub starts over: the last refusal no longer applies.
    public func forgetRefusal() { refusal = nil }
}

/// GitHub's install redirect handed back to this app (#46018): the connect this app started named
/// `<scheme>://integration/complete` as its return link, so the console's callback sends the person's browser straight
/// on to it with GitHub's `code`, `installation_id` and the signed `state`, and shows no page and asks no web sign-in.
/// The app finishes the connection with its own sign-in (``CloudOwnerAPIClient/gitHubComplete(_:)``); the API still
/// completes only a state it signed for this same person and team.
public struct CloudGitHubCompletion: Equatable, Sendable {
    public let state: String
    public let code: String?
    public let installationID: String?
    public let setupAction: String?
    /// GitHub's `error` (the person cancelled): nothing to complete.
    public let error: String?

    /// The return link a connect from this build asks for: `<scheme>://integration/complete`.
    public static func link(scheme: String) -> String { "\(scheme)://integration/complete" }

    /// `url` when it is this build's (`scheme`) completion link with a signed state; nil for any other URL.
    public init?(url: URL, scheme: String) {
        guard url.scheme?.lowercased() == scheme.lowercased(), url.host?.lowercased() == "integration", url.path == "/complete",
              url.user == nil, url.password == nil, url.port == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? {
            guard let raw = items.first(where: { $0.name == name })?.value, !raw.isEmpty, raw.utf8.count <= 4096 else { return nil }
            return raw
        }
        guard let state = value("state"), state.split(separator: ".", omittingEmptySubsequences: false).count == 3 else { return nil }
        self.state = state
        code = value("code")
        installationID = value("installation_id").flatMap { $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) ? $0 : nil }
        setupAction = value("setup_action")
        error = value("error")
    }

    /// The state's `team` claim (`team_` and 20 hex), unverified: only where the completion is sent (`x-cmux-team`),
    /// as the console's callback routes it. The API checks the state's team against the session's.
    public var team: String? {
        guard let team = Self.claims(state)?["team"] as? String,
              team.range(of: #"^team_[0-9a-f]{20}$"#, options: .regularExpression) != nil else { return nil }
        return team
    }

    /// The organization the connect was for (the state's `repo` claim's owner), unverified: words only.
    public var repoOwner: String? {
        guard let repo = Self.claims(state)?["repo"] as? String, let owner = repo.split(separator: "/").first,
              owner.range(of: #"^[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil else { return nil }
        return String(owner)
    }

    /// GitHub's answer for an organization member who may not install the App: a request went to the owners, and there
    /// is no installation to finish (the API refuses it as `integration.state_invalid`, which read as an expired link).
    public var isOwnerRequest: Bool { setupAction == "request" && installationID == nil && error == nil }

    /// A JWT's payload claims, unverified.
    static func claims(_ state: String) -> [String: Any]? {
        let parts = state.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The same key the console's callback sends (dashboard `integrationCompletionKey`): the state and the exact params
    /// GitHub gave. The same redirect again replays; another redirect of the same state (a code-less update redirect,
    /// then the one with a code, or a new installation id) is its own completion. Keyed on the state alone, that second
    /// one was refused for good as `idempotency.conflict` (#55104). FNV-1a 64 of the params: the code is never in a key.
    public var idempotencyKey: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(code ?? "")\n\(installationID ?? "")\n\(setupAction ?? "")".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return "complete:" + String(state.suffix(40)) + ":" + String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// `integration.complete`'s params: the state and what GitHub gave.
    public var params: [String: String] {
        var params = ["state": state]
        if let code { params["code"] = code }
        if let installationID { params["installation_id"] = installationID }
        if let setupAction { params["setup_action"] = setupAction }
        return params
    }
}

extension CloudGitHubCompletion {
    /// The cmux consoles whose `/integrations/callback` is the GitHub App's Setup and Callback URL.
    public static let consoleHosts: Set<String> = ["console.cmux.dev", "console-staging.cmux.dev"]
    /// The console path GitHub sends a person back to.
    public static let consoleCallbackPath = "/integrations/callback"
    /// The console that answers this build's GitHub returns (the API's `DASHBOARD_ORIGIN`).
    public static func consoleHost(production: Bool) -> String { production ? "console.cmux.dev" : "console-staging.cmux.dev" }

    /// What the app does with GitHub's return to the console, caught before the page loads.
    public enum SetupReturn: Equatable, Sendable {
        /// This build's own completion link (``link(scheme:)``) with GitHub's params: the app finishes it itself.
        case complete(URL)
        /// GitHub came back from an installation that already existed with no `code`: go on through the API's
        /// authorize route (the console's own bounce, `integrationAuthorizeBounce`), and GitHub returns again with one.
        case authorize(URL)
    }

    /// GitHub's return to the console after the person saved an installation's settings page (`installation_id`,
    /// `setup_action=update`, no state): the console's `integrationSavedOnGitHub` page, which the app's sheet skips.
    public static func isSavedOnGitHub(_ url: URL) -> Bool {
        guard isConsoleCallback(url), let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value.flatMap { $0.isEmpty ? nil : $0 } }
        guard value("state") == nil, value("error") == nil, value("setup_action") == "update", let id = value("installation_id") else { return false }
        return id.count <= 20 && id.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// `url` is a cmux console's `/integrations/callback` over https.
    public static func isConsoleCallback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host(percentEncoded: false)?.lowercased(), consoleHosts.contains(host),
              url.port == nil || url.port == 443, url.user == nil else { return false }
        return url.path == consoleCallbackPath || url.path == consoleCallbackPath + "/"
    }

    /// GitHub's return to the console's `/integrations/callback` for a connect this build started (the signed state's
    /// `ret` is this build's completion link), as the app finishes it with no page: nil for any other URL, another
    /// build's or the web's connect, and the console's own expired-link answer (which only the page words).
    public static func setupReturn(_ url: URL, scheme: String, api: URL) -> SetupReturn? {
        guard isConsoleCallback(url), let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value.flatMap { $0.isEmpty ? nil : $0 } }
        guard let state = value("state"), let claims = claims(state), claims["provider"] as? String == "github",
              (claims["ret"] as? String)?.lowercased() == link(scheme: scheme).lowercased() else { return nil }
        if value("error") == "connection_link_expired" { return nil }
        if let installation = value("installation_id"), value("code") == nil, value("error") == nil, value("setup_action") != "request" {
            var bounce = URLComponents(url: api.appending(path: "v1/integrations/github/authorize"), resolvingAgainstBaseURL: false)
            bounce?.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "installation_id", value: installation)]
            return bounce?.url.map(SetupReturn.authorize)
        }
        var own = URLComponents()
        own.scheme = scheme
        own.host = "integration"
        own.path = "/complete"
        own.queryItems = items.filter { ["state", "code", "installation_id", "setup_action", "error"].contains($0.name) }
        guard let link = own.url, CloudGitHubCompletion(url: link, scheme: scheme) != nil else { return nil }
        return .complete(link)
    }
}

/// The app's own GitHub panel (CmuxNextAccounts `GitHubInstallSheet`): which pages open in it, which return ends it, which
/// goes on, and how the app finishes it. Leo, 2026-11-25: "you're already in the app. so it shouldnt say shit".
extension CloudGitHubCompletion {
    /// A github.com page over https (the App's install page, its account chooser, an installation's settings).
    public static func opensInApp(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host(percentEncoded: false)?.lowercased() == "github.com" && url.user == nil
    }

    /// GitHub's return that ends the panel: this build's completion link, the console's callback for it, or a save on an
    /// installation's settings page.
    public static func endsInApp(_ url: URL, scheme: String, api: URL) -> Bool {
        if CloudGitHubCompletion(url: url, scheme: scheme) != nil || isSavedOnGitHub(url) { return true }
        if case .complete? = setupReturn(url, scheme: scheme, api: api) { return true }
        return false
    }

    /// A code-less return from an installation that already existed goes on through the API's authorize route.
    public static func nextInApp(_ url: URL, scheme: String, api: URL) -> URL? {
        if case .authorize(let next)? = setupReturn(url, scheme: scheme, api: api) { return next }
        return nil
    }

    /// The console callback for this build as the app's own completion link (a WebKit tab hands it over instead of loading).
    @MainActor public static func ownReturn(_ url: URL, auth: CloudAuth) -> URL? {
        guard case .complete(let own)? = setupReturn(url, scheme: auth.configuration.callbackScheme,
                                                     api: auth.configuration.ownerAPIBaseURL()) else { return nil }
        return own
    }

    /// Finishes the panel's end: a save on GitHub re-reads, a return finishes the connect, anything else closes it.
    @MainActor public static func finishInApp(_ url: URL, auth: CloudAuth) {
        if isSavedOnGitHub(url) { return auth.gitHubChanges.savedOnGitHub() }
        if !handle(ownReturn(url, auth: auth) ?? url, auth: auth) { auth.gitHubChanges.closedGitHub() }
    }
}

extension CloudGitHubCompletion {
    /// Finishes `url` when it is this build's completion link (``CloudGitHubCompletion/link(scheme:)``) with `auth`'s
    /// own sign-in, counts it in ``CloudAuth/gitHubChanges`` and hands its answer to `answered` (the app shows the
    /// person what happened); false for any other URL. A cancel on GitHub finishes nothing.
    @MainActor public static func handle(_ url: URL, auth: CloudAuth,
                                         answered: @escaping @MainActor (CloudOwnerAPIClient.GitHubCompletion) -> Void = { _ in }) -> Bool {
        guard let completion = CloudGitHubCompletion(url: url, scheme: auth.configuration.callbackScheme) else { return false }
        guard completion.error == nil else {
            auth.gitHubChanges.closedGitHub()
            return true
        }
        // An organization member's request: GitHub sent it to the owners, and the app says so (no API call to refuse it).
        if completion.isOwnerRequest {
            auth.gitHubChanges.recordRequested(owner: completion.repoOwner)
            answered(.pendingApproval(message: nil))
            return true
        }
        auth.gitHubChanges.finishing()
        let base = auth.configuration.ownerAPIBaseURL(), team = completion.team
        // task-owner: fire and forget; one completion per redirect, keyed so a repeated link is the same completion.
        Task { @MainActor in
            await auth.awaitRestored()
            guard auth.isSignedIn else { return auth.gitHubChanges.record(.noAnswer, reason: nil) }
            let access: CloudOwnerAPIClient.AccessToken = { try await auth.tokens().access }
            let reply = await CloudOwnerAPIClient(baseURL: base, accessToken: access, teamID: { team }, buildSpace: auth.configuration.buildSpace)
                .gitHubCompleteWithAccount(completion)
            auth.gitHubChanges.record(reply.answer, reason: reply.reason, account: reply.account)
            answered(reply.answer)
        }
        return true
    }
}

extension CloudOwnerAPIClient {
    /// What one completion answered.
    public enum GitHubCompletion: Equatable, Sendable {
        case connected
        /// GitHub sent the install to the organization's owners (``CloudGitHubCompletion/isOwnerRequest``): not an
        /// error, nothing linked until an owner approves; `message` is the API's words for the person, when it gave any.
        case pendingApproval(message: String?)
        /// The API refused it (a state for someone else, expired, or GitHub refused the code); `message` is the API's
        /// words for the person, when it gave any.
        case refused(message: String?)
        case noAnswer
    }

    /// `integration.complete` on `/v1/ops` as the person, in ``teamID``'s team, under the console's own key.
    public func gitHubComplete(_ completion: CloudGitHubCompletion) async -> GitHubCompletion {
        await gitHubCompleteWithReason(completion).answer
    }

    /// ``gitHubComplete(_:)`` and, for a refusal, the API's own words (``refusalReason(body:)``).
    public func gitHubCompleteWithReason(_ completion: CloudGitHubCompletion) async -> (answer: GitHubCompletion, reason: String?) {
        let reply = await gitHubCompleteWithAccount(completion)
        return (reply.answer, reply.reason)
    }

    /// ``gitHubCompleteWithReason(_:)`` and, when connected, the GitHub account's name (``connectedAccount(body:)``).
    public func gitHubCompleteWithAccount(_ completion: CloudGitHubCompletion) async -> (answer: GitHubCompletion, reason: String?, account: String?) {
        let body: [String: Any] = ["op": "integration.complete", "params": completion.params, "origin": "user", "idempotency_key": completion.idempotencyKey]
        guard let json = try? JSONSerialization.data(withJSONObject: body), let answer = await person("/v1/ops", post: json) else { return (.noAnswer, nil, nil) }
        let result = Self.completion(status: answer.status, body: answer.body, ownerRequest: completion.isOwnerRequest)
        switch result {
        case .refused: return (result, Self.refusalReason(body: answer.body), nil)
        case .connected: return (result, nil, Self.connectedAccount(body: answer.body))
        case .pendingApproval, .noAnswer: return (result, nil, nil)
        }
    }

    /// The connected account's name from `integration.complete`'s reply (`{value: {account: {name}}}` or the result at
    /// the top level), capped; nil when it gave none.
    static func connectedAccount(body: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        let value = (object["value"] as? [String: Any]) ?? (object["result"] as? [String: Any]) ?? object
        let connection = (value["connection"] as? [String: Any]) ?? value
        guard let name = (connection["account"] as? [String: Any])?["name"] as? String else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(100))
    }

    /// The API's message for a refused completion (`{error: {code, message}}`), trimmed and capped; nil when it gave none,
    /// or when it is the expired or invalid `state` (`integration.state_invalid` and kin), which the client words itself.
    static func refusalReason(body: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        let code = (error["code"] as? String ?? "").lowercased()
        guard !code.contains("state") else { return nil }
        let text = (error["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(200))
    }

    /// A 2xx answer that says `ok` (no error) is connected; a 408, 429 or 5xx may not have run; anything else refused,
    /// with the API's `error.message`; a refused owner request (`ownerRequest`) is pending an owner's approval.
    static func completion(status: Int, body: Data, ownerRequest: Bool = false) -> GitHubCompletion {
        guard status < 500, status != 408, status != 429 else { return .noAnswer }
        let reply = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        guard (200..<300).contains(status), let reply, reply["ok"] as? Bool != false, reply["error"] == nil || reply["error"] is NSNull else {
            let said = ((reply?["error"] as? [String: Any])?["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = said?.isEmpty == false ? said : nil
            return ownerRequest ? .pendingApproval(message: message) : .refused(message: message)
        }
        return .connected
    }
}
