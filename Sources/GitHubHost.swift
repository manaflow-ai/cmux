import Foundation

/// A GitHub-family host that cmux can talk to through the GitHub REST API.
///
/// A host is either github.com (the public SaaS) or a GitHub Enterprise Server
/// (GHES) instance such as `ghe.example.com`. The workspace pull-request poller
/// in `TabManager` uses this type to derive a per-host REST API base URL and to
/// look up a per-host authentication token, instead of hardcoding `github.com`.
///
/// The same helper is intended to be adopted by other GitHub-talking subsystems
/// (for example `CLI/cmux_open.swift`) so that GHES support does not have to be
/// re-derived ad hoc at every call site.
struct GitHubHost: Hashable, Sendable {
    /// The bare, lowercased hostname, e.g. `github.com` or `ghe.example.com`.
    let hostname: String

    /// Creates a host from a raw hostname. The hostname is lowercased so that
    /// hosts compare and hash case-insensitively.
    init(hostname: String) {
        self.hostname = hostname.lowercased()
    }

    /// The canonical github.com host.
    static let dotCom = GitHubHost(hostname: "github.com")

    /// Whether this host is github.com (the public SaaS host).
    ///
    /// github.com serves public repositories without authentication, so the
    /// poller may query it even when no token is available; every other host
    /// requires a token (see ``isPollable(token:)``).
    var isDotCom: Bool { hostname == "github.com" }

    /// The REST API base URL for this host.
    ///
    /// github.com maps to `https://api.github.com/`; any GitHub Enterprise
    /// Server host maps to `https://<host>/api/v3/`. The returned URL always
    /// ends in a trailing slash so endpoint paths can be appended relative to it
    /// (see ``apiURL(endpoint:)``).
    var apiBaseURL: URL {
        // NOTE: current (pre-fix) behavior hardcodes github.com's API host.
        // The GHES-aware implementation lands alongside the TabManager wiring.
        URL(string: "https://api.github.com/")!
    }

    /// Builds an absolute REST API URL for an endpoint path relative to ``apiBaseURL``.
    ///
    /// - Parameter endpoint: A path (and optional query) relative to the API
    ///   base, e.g. `repos/owner/repo/pulls?state=all`.
    /// - Returns: The absolute URL, or `nil` if `endpoint` is not a valid URL
    ///   component.
    func apiURL(endpoint: String) -> URL? {
        URL(string: endpoint, relativeTo: apiBaseURL)?.absoluteURL
    }

    /// A shell-out closure used to resolve an auth token for a host.
    ///
    /// The closure receives an executable name and its arguments and returns the
    /// captured standard output, or `nil` if the command failed or produced no
    /// output. Injecting the runner keeps ``authToken(using:)`` testable without
    /// spawning a real process.
    typealias TokenCommandRunner = @Sendable (_ executable: String, _ arguments: [String]) async -> String?

    /// Looks up an authentication token for this host via the GitHub CLI.
    ///
    /// Absence of a token is **not** an error: it means the user is not
    /// authenticated to this host, and the poller should silently skip it.
    ///
    /// - Parameter runner: The shell-out closure used to invoke `gh`.
    /// - Returns: The trimmed token, or `nil` when `gh` reports no token.
    func authToken(using runner: TokenCommandRunner) async -> String? {
        // NOTE: current (pre-fix) behavior omits the `--hostname` flag, so the
        // token for github.com is always returned regardless of `hostname`.
        let raw = await runner("gh", ["auth", "token"])
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the workspace pull-request poller should issue requests to this
    /// host given a resolved token.
    ///
    /// github.com is pollable even without a token (it serves public
    /// repositories anonymously); every other host requires a non-empty token.
    /// This is the gate that silently drops non-GitHub remotes (gitlab.com,
    /// bitbucket.org, …) — `gh` has no token for them, so they are never polled.
    ///
    /// - Parameter token: The token resolved for this host, or `nil`.
    /// - Returns: `true` if the poller may query this host.
    func isPollable(token: String?) -> Bool {
        isDotCom || (token?.isEmpty == false)
    }
}
