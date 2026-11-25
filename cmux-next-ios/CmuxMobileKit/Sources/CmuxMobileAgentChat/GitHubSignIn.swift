import Foundation

// Sign in with GitHub on the phone (Leo, 2026-11-25: "You need to just do this and wire it up";
// "Convienient beats all. Just make good ui for it so people flow."). A Cloud chat needs GitHub on
// its machine. The Mac carries its own gh login there; the phone has none, so on the phone the
// way is always Sign in with GitHub: the account's cmux GitHub App connect (install, pick
// repositories, back to cmux), then the start runs again or the chat goes on. Two places ask:
//   - a Cloud start refused with `seed.needs_github` (its details: `repo`, `githubLogin`
//     `carried | none | not_carried`, maybe `githubUser`);
//   - a chat's GitHub call refused because the team has no connection (`github.not_connected`,
//     `integration.not_found`, `needs_reauth`, `policy.denied`) or because the App's installation
//     has not accepted its updated permissions (`github.permissions_pending`). The Mac's reader is
//     webviews `githubConnect.ts`; this one keys on the same two shapes.

/// Why a Cloud chat needs GitHub, and the repository when one is named.
public struct GitHubSignInNeed: Hashable, Sendable {
    /// Whose gh login the start carried to the machine (`seed.needs_github` `githubLogin`).
    public enum Login: String, Hashable, Sendable {
        /// The start carried a login, and it can't reach the repository.
        case carried
        /// No login to carry (always so from a phone).
        case none
        /// There was a login, and it was not carried.
        case notCarried = "not_carried"
    }

    public enum Reason: Hashable, Sendable {
        /// A Cloud start's machine could not clone the repository (`seed.needs_github`).
        case clone(login: Login?, user: String?)
        /// The cmux GitHub App's installation has not accepted its updated permissions.
        case permissionsPending
        /// The team has no GitHub connection, or one that needs linking again.
        case notConnected
        /// The connection does not cover the repository.
        case notCovered
    }

    public var reason: Reason
    /// `OWNER/REPO`, only when it is well formed.
    public var repo: String?

    public init(reason: Reason, repo: String? = nil) {
        self.reason = reason
        self.repo = repo.flatMap { Self.isRepo($0) ? $0 : nil }
    }

    /// A Cloud start's refusal code.
    public static let cloneCode = "seed.needs_github"
    /// A GitHub call's refusal while the App's updated permissions wait on the installation.
    public static let permissionsPendingCode = "github.permissions_pending"

    /// A Cloud start's refusal: `seed.needs_github` with its details (`repo`, `githubLogin`,
    /// `githubUser`), or nil for any other code. `repo` is the start's own repository, used when
    /// the details name none.
    public init?(startCode code: String?, details: JSONValue?, repo fallback: String? = nil) {
        guard code == Self.cloneCode else { return nil }
        let login = details?["githubLogin"]?.stringValue.flatMap(Login.init(rawValue:))
        let user = details?["githubUser"]?.stringValue.flatMap { Self.isOwner($0) ? $0 : nil }
        let named = details?["repo"]?.stringValue
        self.init(reason: .clone(login: login, user: user),
                  repo: named.flatMap { Self.isRepo($0) ? $0 : nil } ?? fallback.flatMap(Self.repo(remote:)))
    }

    /// The line the card says.
    public var line: String {
        switch reason {
        case let .clone(login, user):
            if login == .carried, let user {
                if let repo {
                    return String(format: GitHubSignInWords.loginCantReach, user, repo)
                }
                return String(format: GitHubSignInWords.loginCantReachRepo, user)
            }
            if let repo { return String(format: GitHubSignInWords.cloneNeedsAccess, repo) }
            return GitHubSignInWords.cloneNeedsAccessRepo
        case .permissionsPending:
            return GitHubSignInWords.permissionsPending
        case .notConnected:
            if let repo { return String(format: GitHubSignInWords.notConnected, repo) }
            return GitHubSignInWords.notConnectedRepo
        case .notCovered:
            if let repo { return String(format: GitHubSignInWords.notCovered, repo) }
            return GitHubSignInWords.notConnectedRepo
        }
    }

    // MARK: - A chat's GitHub call

    /// The need a turn's calls ask for: its last finished call that a GitHub refusal ended.
    static func turn(_ items: [TurnItem]) -> GitHubSignInNeed? {
        for case .tool(let call) in items.reversed() where !call.isRunning {
            if let need = Self(call: call) { return need }
        }
        return nil
    }

    /// The prompt the chat's card sends once the person is back from GitHub (the Mac's
    /// `CONTINUE_PROMPT`).
    public static let continuePrompt = "Continue"

    /// What a failed call asks of GitHub, or nil for any other call. The repository comes only from
    /// the cmux GitHub MCP server's own error and the call's arguments to that server; text a call
    /// printed never names it (a file or page could carry a refusal-shaped line).
    public init?(call: ACPToolCall) {
        guard call.status == .failed || (call.exitCode ?? 0) != 0 else { return nil }
        var text = call.outputText
        if text.isEmpty, let raw = call.rawOutput?.stringValue { text = raw }
        var structured = Self.structured(call.rawOutput)
        // A failed call's output is read only when it names GitHub, and from its last 64 KB.
        guard structured != nil || text.contains("github") else { return nil }
        if text.utf8.count > 65_536 { text = String(text.suffix(65_536)) }
        if structured == nil, text.first(where: { !$0.isWhitespace }) == "{" {
            structured = Self.structured(JSONValue(jsonData: Data(text.utf8)))
        }
        let shell = call.command != nil || call.kind == .execute
        if !shell, let mcp = WhoElseCall.mcpCall(call) {
            guard mcp.server.lowercased() == "github" else { return nil }
            let argsRepo = Self.repoOfArgs(call.rawInput)
            if let structured {
                self.init(reason: structured.reason, repo: argsRepo ?? structured.repo)
                return
            }
            guard let reason = Self.lineReason(text) else { return nil }
            self.init(reason: reason, repo: argsRepo)
            return
        }
        guard let command = call.command, command.range(of: #"(?:^|[\s;&|(])(?:git|gh)\s"#, options: .regularExpression) != nil,
              let reason = Self.lineReason(text) else { return nil }
        self.init(reason: reason)
    }

    static func reason(code: String?) -> Reason? {
        switch code {
        case "integration.not_found", "github.not_connected", "needs_reauth": .notConnected
        case "policy.denied": .notCovered
        case permissionsPendingCode, "permissions_pending": .permissionsPending
        default: nil
        }
    }

    /// The MCP error at the top of the call's result only (`structuredContent.error`, or `error`).
    /// A not-connected refusal names the connect action; the permissions refusal is its own code.
    private static func structured(_ value: JSONValue?) -> (reason: Reason, repo: String?)? {
        guard case .object(let root)? = value else { return nil }
        let error: JSONValue? = if case .object(let content)? = root["structuredContent"] { content["error"] } else { root["error"] }
        guard case .object(let fields)? = error else { return nil }
        let reason = reason(code: fields["detail"]?.stringValue) ?? reason(code: fields["code"]?.stringValue)
        guard let reason else { return nil }
        if reason != .permissionsPending, fields["connect"]?["action"]?.stringValue != "accounts.githubConnect" { return nil }
        return (reason, fields["repo"]?.stringValue)
    }

    nonisolated(unsafe) private static let codePattern = try? NSRegularExpression(
        pattern: #"\b(integration\.not_found|github\.not_connected|github\.permissions_pending|needs_reauth|policy\.denied)\b"#)

    /// The agent side's one refusal line (`cmux github credential: …`, `cmux could not get a token …`)
    /// that names the next step: a file that only mentions the words is not one.
    private static func lineReason(_ text: String) -> Reason? {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.range(of: #"^cmux (?:github\b|could not get a token\b)"#, options: .regularExpression) != nil,
                  line.contains("Next: "), let codePattern,
                  let match = codePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { continue }
            return reason(code: String(line[range]))
        }
        return nil
    }

    private static func repoOfArgs(_ input: JSONValue?) -> String? {
        let args = input?["arguments"] ?? input
        guard let owner = args?["owner"]?.stringValue, let repo = args?["repo"]?.stringValue else { return nil }
        return "\(owner)/\(repo)"
    }

    // MARK: - Names

    /// A GitHub repository's full name as GitHub allows it (the Mac's `isGitHubRepo`).
    public static func isRepo(_ value: String) -> Bool {
        guard value.count <= 140,
              value.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil
        else { return false }
        let name = value.split(separator: "/").last.map(String.init) ?? ""
        return name != "." && name != ".."
    }

    /// A GitHub account or org name (the Mac's `isGitHubOwner`).
    public static func isOwner(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$"#, options: .regularExpression) != nil
    }

    /// `OWNER/REPO` of a github.com remote (`https://github.com/o/r(.git)`, `git@github.com:o/r.git`).
    public static func repo(remote: String) -> String? {
        var rest = remote.trimmingCharacters(in: .whitespaces)
        for prefix in ["https://github.com/", "http://github.com/", "ssh://git@github.com/", "git@github.com:"] where rest.hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
            if rest.hasSuffix("/") { rest.removeLast() }
            if rest.hasSuffix(".git") { rest.removeLast(4) }
            return isRepo(rest) ? rest : nil
        }
        return isRepo(rest) ? rest : nil
    }
}

/// The words of Sign in with GitHub, shared by the Cloud start and the chat's card.
public enum GitHubSignInWords {
    public static var signIn: String {
        String(localized: "mobile.github.signIn", defaultValue: "Sign in with GitHub", bundle: .module)
    }
    public static var waiting: String {
        String(localized: "mobile.github.signIn.waiting", defaultValue: "Finish on GitHub, then come back.", bundle: .module)
    }
    public static var failedTitle: String {
        String(localized: "mobile.github.signIn.failed", defaultValue: "Couldn't sign in with GitHub", bundle: .module)
    }
    static var cloneNeedsAccess: String {
        String(localized: "mobile.github.cloneNeedsAccess", defaultValue: "Sign in with GitHub so Cloud can clone %@.", bundle: .module)
    }
    static var cloneNeedsAccessRepo: String {
        String(localized: "mobile.github.cloneNeedsAccess.noRepo", defaultValue: "Sign in with GitHub so Cloud can clone this repository.", bundle: .module)
    }
    static var loginCantReach: String {
        String(localized: "mobile.github.loginCantReach", defaultValue: "GitHub account %1$@ doesn't have access to %2$@. Sign in with GitHub to give Cloud access.", bundle: .module)
    }
    static var loginCantReachRepo: String {
        String(localized: "mobile.github.loginCantReach.noRepo", defaultValue: "GitHub account %@ doesn't have access to this repository. Sign in with GitHub to give Cloud access.", bundle: .module)
    }
    static var permissionsPending: String {
        String(localized: "mobile.github.permissionsPending", defaultValue: "GitHub needs you to accept cmux's updated permissions", bundle: .module)
    }
    static var notConnected: String {
        String(localized: "mobile.github.notConnected", defaultValue: "This chat needs GitHub access to %@.", bundle: .module)
    }
    static var notConnectedRepo: String {
        String(localized: "mobile.github.notConnected.noRepo", defaultValue: "This chat needs GitHub access.", bundle: .module)
    }
    static var notCovered: String {
        String(localized: "mobile.github.notCovered", defaultValue: "cmux's GitHub access doesn't include %@.", bundle: .module)
    }
}

#if os(iOS)
import CmuxSpinner
import SwiftUI

/// Runs Sign in with GitHub for a repository (nil: the account's) and answers true once the person
/// is back and the start or chat should go on: GitHub already covered it, or its page was opened
/// and the app came back. False: it did not run (its reason was shown).
public typealias GitHubSignInAction = @MainActor @Sendable (_ repo: String?) async -> Bool

/// Where the cards find the account's GitHub connect: set once by the app shell (a static, not an
/// environment value, because the transcript's rows and the shell's tabs sit in hosting
/// controllers of their own). Nil: the cards' button is off.
@MainActor
public enum GitHubSignInHook {
    public static var run: GitHubSignInAction?
}

/// One line and one Sign in with GitHub button. Coming back from GitHub runs `then` (the start
/// again, or the chat's Continue).
public struct GitHubSignInCard: View {
    let need: GitHubSignInNeed
    let then: @MainActor () -> Void
    @State private var working = false
    private var signIn: GitHubSignInAction? { GitHubSignInHook.run }

    public init(need: GitHubSignInNeed, then: @escaping @MainActor () -> Void) {
        self.need = need
        self.then = then
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(verbatim: need.line).font(.subheadline)
            } icon: {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
            }
            Button {
                guard let signIn, !working else { return }
                working = true
                Task {
                    let back = await signIn(need.repo)
                    working = false
                    if back { then() }
                }
            } label: {
                HStack(spacing: 8) {
                    if working { CmuxSpinner() }
                    Text(verbatim: GitHubSignInWords.signIn)
                }
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .disabled(signIn == nil || working)
            .accessibilityIdentifier("github.signIn")
            if working {
                Text(verbatim: GitHubSignInWords.waiting).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("github.signInCard")
    }
}
#endif
