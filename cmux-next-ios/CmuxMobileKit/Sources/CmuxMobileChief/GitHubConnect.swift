import Foundation
import Observation

/// Connect GitHub (the Mac's `accounts.githubConnect`): the cmux GitHub App on the account,
/// through the account's own `integration.list` and `integration.connect {provider: github}`.
/// Connecting opens the App's installation page on GitHub; the list says when it took.
@MainActor
@Observable
public final class GitHubConnect {
    public enum State: Equatable, Sendable {
        case unknown
        /// This service has no GitHub App configured.
        case unavailable
        case notConnected
        /// An installation was started and is not finished yet.
        case pending
        /// Connected, with the GitHub accounts it covers.
        case connected([String])
    }

    public private(set) var state: State = .unknown
    public private(set) var working = false
    public var failure: String?

    @ObservationIgnored private let account: @MainActor () -> AccountCloud?
    @ObservationIgnored private let open: @MainActor (URL) -> Void
    /// One key per installation attempt, so a retried connect makes one connection.
    @ObservationIgnored private var connectKey: String?

    public init(account: @escaping @MainActor () -> AccountCloud?, open: @escaping @MainActor (URL) -> Void) {
        self.account = account
        self.open = open
    }

    /// Reads the account's connections.
    public func refresh() async {
        guard let account = account() else {
            state = .unknown
            return
        }
        // A list that does not load leaves the row without a value; only Connect itself says why.
        guard let value = try? await account.read("integration.list") else { return }
        state = Self.state(value)
        forgetFinishedAttempt()
    }

    /// A connection no longer pending (finished, abandoned or expired) ends its attempt: the next
    /// Connect makes a new one rather than replaying the old installation link.
    private func forgetFinishedAttempt() {
        if state != .pending { connectKey = nil }
    }

    /// Connect GitHub: the list first (already connected: nothing to do), then the page GitHub
    /// needs. `repo` (a chat's failed call's `OWNER/REPO`) and `returnTo` (that chat's cmux link)
    /// come from a chat's Connect GitHub: with a repository the API decides what covers it, so an
    /// active connection elsewhere does not end it; `connected: true` is done and opens nothing;
    /// GitHub's return opens `returnTo`. The Mac's `connect(repo:returnTo:)` is the same.
    public func connect(repo: String? = nil, returnTo: String? = nil) async {
        guard !working, let account = account() else { return }
        working = true
        defer { working = false }
        failure = nil
        do {
            state = Self.state(try await account.read("integration.list"))
            forgetFinishedAttempt()
            if case .connected = state, repo == nil { return }
            guard state != .unavailable else {
                failure = String(localized: "GitHub isn't set up on this cmux Cloud.")
                return
            }
            let key = connectKey ?? UUID().uuidString.lowercased()
            connectKey = key
            var params: [String: any Sendable] = ["provider": "github"]
            if let repo { params["repo"] = repo }
            if let returnTo { params["return_to"] = returnTo }
            let value = try await account.mutate("integration.connect", params: params, key: key)
            let object = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any]
            if object?["connected"] as? Bool == true {
                // Already covered: nothing to open; the list says so.
                connectKey = nil
                state = Self.state(try await account.read("integration.list"))
                return
            }
            guard let raw = object?["authorize_url"] as? String, let url = Self.installationURL(raw) else {
                connectKey = nil
                failure = AccountCloud.Failure.badReply.description
                return
            }
            state = .pending
            open(url)
        } catch let refusal as AccountCloud.Failure {
            // A definite refusal starts over with a new key; a lost answer keeps it for the retry.
            if case .refused = refusal { connectKey = nil }
            failure = refusal.description
        } catch {
            failure = AccountCloud.Failure.unreachable.description
        }
    }

    /// The state an `integration.list` value gives (revoked and expired connections do not count).
    static func state(_ value: Data) -> State {
        guard let root = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any] else { return .unknown }
        let providers = root["providers"] as? [[String: Any]] ?? []
        let configured = providers.contains { $0["provider"] as? String == "github" && $0["configured"] as? Bool == true }
        let connections = (root["connections"] as? [[String: Any]] ?? []).filter {
            $0["provider"] as? String == "github" && !["revoked", "expired"].contains($0["status"] as? String ?? "")
        }
        // Connected means an active connection (the Mac's check); an errored one can connect again.
        let active = connections.filter { $0["status"] as? String == "active" }
        if !active.isEmpty {
            return .connected(active.compactMap { $0["account_login"] as? String ?? $0["display_name"] as? String })
        }
        if connections.contains(where: { $0["status"] as? String == "pending" }) { return .pending }
        return configured ? .notConnected : .unavailable
    }

    /// Only the GitHub pages `integration.connect` answers may open (the Mac's check): the App's
    /// installation page, its page for one owner, and GitHub's OAuth authorize page.
    public nonisolated static func installationURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", url.host() == "github.com",
              url.user == nil, url.password == nil, url.port == nil,
              connectPaths.contains(where: { url.path().range(of: $0, options: .regularExpression) != nil }) else { return nil }
        return url
    }

    /// The paths of the pages ``installationURL(_:)`` lets open.
    nonisolated static let connectPaths = [
        #"^/apps/[A-Za-z0-9-]+/installations/new$"#,
        #"^/apps/[A-Za-z0-9-]+/installations/new/permissions$"#,
        #"^/login/oauth/authorize$"#,
    ]
}

#if os(iOS)
import CmuxSpinner
import SwiftUI
import UIKit

/// Settings → Cloud → Connect GitHub: the state, and a tap that connects (the App's installation
/// page on GitHub). Read again when the app comes back from GitHub.
public struct GitHubConnectRow: View {
    @State private var model = GitHubConnect(account: { ChiefSources.shared.account },
                                             open: { UIApplication.shared.open($0) })
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        Button {
            Task { await model.connect() }
        } label: {
            HStack {
                Label("Connect GitHub", systemImage: "link")
                Spacer()
                if model.working {
                    CmuxSpinner()
                } else if let value {
                    Text(value).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(model.working || isConnected)
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
        .alert("Couldn't connect GitHub", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.failure ?? "")
        }
        .accessibilityIdentifier("settings.connectGitHub")
        .accessibilityValue(value ?? "")
    }

    private var isConnected: Bool {
        if case .connected = model.state { return true }
        return false
    }

    private var value: String? {
        switch model.state {
        case .unknown: nil
        case .unavailable: String(localized: "Not available")
        case .notConnected: String(localized: "Not connected")
        case .pending: String(localized: "Finish on GitHub")
        case let .connected(logins): logins.isEmpty ? String(localized: "Connected") : logins.joined(separator: ", ")
        }
    }
}
#endif
