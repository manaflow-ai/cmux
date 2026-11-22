import CmuxNextApps
public import Foundation

/// Demo data: the five first-party apps (first-party-apps.md section 2),
/// one made-up Verified app and one made-up unverified app, installed with
/// their tier defaults plus a few user changes. Changes go through the
/// real reducer, so the demo behaves like the owner.
@MainActor
public final class AppPermissionsMockSource: AppPermissionsDataSource {
    public private(set) var listings: [AppPermissionsListing]
    private var records: [String: AppPermissionRecord] = [:]
    private var log: [String: [AppActivityEntry]] = [:]
    private let now: Date

    public let workspaces = [AppResourceOption(id: "ws_1", name: "cmux"), AppResourceOption(id: "ws_2", name: "web"),
                             AppResourceOption(id: "ws_3", name: "notes")]
    public let rooms = [AppResourceOption(id: "room_1", name: "Design review")]
    public let machines = [AppResourceOption(id: "mac_1", name: "This Mac"), AppResourceOption(id: "vm_1", name: "Cloud VM")]

    /// `now` fixes activity times (snapshots).
    public init(now: Date = Date()) {
        self.now = now
        listings = Self.firstParty + [Self.verifiedSample, Self.unverifiedSample]
        for listing in listings { records[listing.id] = listing.installDraft().record() }
        seedChanges()
        seedActivity()
    }

    public func record(for appID: String) -> AppPermissionRecord? { records[appID] }
    public func activity(for appID: String) -> [AppActivityEntry] { log[appID] ?? [] }

    public func apply(_ change: AppGrantChange, appID: String) async -> Result<AppPermissionRecord, AppGrantRejection> {
        applyNow(change, appID: appID)
    }

    @discardableResult
    func applyNow(_ change: AppGrantChange, appID: String) -> Result<AppPermissionRecord, AppGrantRejection> {
        guard let record = records[appID] else { return .failure(.undeclared(scope: appID)) }
        let result = AppGrantReducer.apply(change, to: record, origin: .user)
        if case .success(let next) = result { records[appID] = next }
        return result
    }

    public func install(_ record: AppPermissionRecord) async { records[record.appID] = record }
    public func removeAppData(appID: String) async { log[appID] = [] }

    public func pickFolder(appID: String) async -> AppFileRoot? {
        AppFileRoot(id: "root_\((records[appID]?.grant.fileRoots.count ?? 0) + 1)", kind: .bookmark, label: "Documents")
    }

    // MARK: Fixtures

    static func request(_ scope: String, _ reason: String) -> AppScopeRequest { AppScopeRequest(scope: scope, reason: reason) }

    public static let firstParty: [AppPermissionsListing] = [
        AppPermissionsListing(
            id: "cmux/search", name: "Search", publisher: "cmux", version: "1.0.0", symbol: "magnifyingglass", tier: .firstParty,
            required: [request("workspace:read", "Find workspaces and tabs."), request("terminal:read", "Search terminal text."),
                       request("browser:read", "Find open browser pages.")],
            optional: [request("history:read", "Search pages you visited."), request("fs:read", "Search files in folders you pick.")]),
        AppPermissionsListing(
            id: "cmux/inbox", name: "Inbox", publisher: "cmux", version: "1.0.0", symbol: "tray", tier: .firstParty,
            required: [request("notification:read", "List your notifications."), request("notification:write", "Mark items done."),
                       request("agent:read", "Show agents that wait or finished."), request("workspace:write", "Open an item's tab."),
                       request("integration:github:read", "Show review requests and failing checks.")]),
        AppPermissionsListing(
            id: "cmux/notes", name: "Notes", publisher: "cmux", version: "1.0.0", symbol: "note.text", tier: .firstParty,
            required: [request("workspace:read", "Keep notes per workspace."), request("storage:synced", "Sync notes to your devices.")],
            optional: [request("mcp:expose", "Let agents read and append notes.")]),
        AppPermissionsListing(
            id: "cmux/coderouter", name: "CodeRouter", publisher: "cmux", version: "1.0.0", symbol: "arrow.triangle.branch",
            tier: .firstParty,
            required: [request("coderouter:read", "Show status, accounts and usage."), request("coderouter:write", "Change routing."),
                       request("coderouter:keys", "Create and revoke keys.")],
            optional: [request("notification:write", "Warn when an account runs out.")]),
        AppPermissionsListing(
            id: "cmux/usage", name: "Usage", publisher: "cmux", version: "1.0.0", symbol: "gauge.with.dots.needle.50percent",
            tier: .firstParty,
            required: [request("usage:read", "Show plan usage and reset times."), request("notification:write", "Warn near a limit.")]),
    ]

    public static let verifiedSample = AppPermissionsListing(
        id: "lumen/pr-radar", name: "PR Radar", publisher: "Lumen Labs", version: "2.3.1", symbol: "dot.radiowaves.left.and.right",
        tier: .verified,
        required: [request("workspace:read", "Match pull requests to workspaces."), request("terminal:read", "Spot test runs."),
                   request("integration:github:read", "Read your pull requests."), request("net:status.lumen.dev", "Fetch CI status."),
                   request("terminal:execute", "Run a check again in its terminal."), request("clipboard:write", "Copy a branch name."),
                   request("mcp:expose", "Offer review commands to agents.")],
        optional: [request("notification:write", "Tell you when a check fails."), request("fs:read", "Read CODEOWNERS in a folder you pick.")],
        reviewed: ["clipboard:write"])

    public static let unverifiedSample = AppPermissionsListing(
        id: "kestrel/snippets", name: "Snippets", publisher: "kestrel", version: "0.4.0", symbol: "text.badge.plus", tier: .unverified,
        required: [request("workspace:read", "Show snippets for this workspace."), request("workspace:write", "Rename tabs after a snippet."),
                   request("terminal:execute", "Paste a snippet into a terminal."), request("net:snippets.kestrel.dev", "Sync your snippets."),
                   request("clipboard:write", "Copy a snippet."), request("fs:write", "Save snippets to a folder.")],
        optional: [request("notification:write", "Remind you of a snippet.")])

    private func seedChanges() {
        applyNow(.setApproval(scope: "terminal:execute", approval: .perCall), appID: Self.verifiedSample.id)
        applyNow(.answerFirstUse(scope: "fs:read", answer: .allow), appID: Self.verifiedSample.id)
        applyNow(.addFileRoot(AppFileRoot(id: "root_1", kind: .workspaceFolder, label: "cmux")), appID: Self.verifiedSample.id)
        applyNow(.answerFirstUse(scope: "fs:read", answer: .allow), appID: "cmux/search")
        applyNow(.addFileRoot(AppFileRoot(id: "root_1", kind: .bookmark, label: "Notes")), appID: "cmux/search")
        applyNow(.setApproval(scope: "net:snippets.kestrel.dev", approval: .perSession), appID: Self.unverifiedSample.id)
    }

    private func seedActivity() {
        func entry(_ id: Int, _ op: String, _ scope: String?, _ origin: String, _ result: AppActivityResult, _ minutes: Double) -> AppActivityEntry {
            AppActivityEntry(id: id, op: op, scope: scope, origin: origin, result: result, time: now.addingTimeInterval(-minutes * 60))
        }
        log[Self.verifiedSample.id] = [
            entry(1, "integration.request", "integration:github:read", "script", .allowed, 2),
            entry(2, "workspace.list", "workspace:read", "script", .allowed, 3),
            entry(3, "pane.run", "terminal:execute", "user", .asked, 18),
            entry(4, "net.fetch", "net:api.example.com", "script", .refused, 41),
            entry(5, "notification.create", "notification:write", "script", .refused, 95),
        ]
        log["cmux/search"] = [entry(1, "terminal.history.read", "terminal:read", "user", .allowed, 1),
                              entry(2, "fs.search", "fs:read", "user", .allowed, 1)]
    }
}
