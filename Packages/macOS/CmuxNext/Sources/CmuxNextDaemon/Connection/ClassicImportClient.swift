public import Foundation

/// The one-time move from classic cmux on the daemon (`classic_import.*`, the
/// `cmux-classic-import` crate, plans/cmux-next/classic-migration-DESIGN.md).
/// The daemon finds and reads classic's saved session, keeps the migration
/// ledger and backups, decides whether a launch runs and plans what a run
/// makes; the app asks the person and makes the workspaces. Both operations
/// are the verified app's only (user or app origin).
public struct ClassicImportClient: Sendable {
    /// Advertised in identify by a daemon that answers both operations.
    public static let capability = "classic-import-v1"

    public let connection: DaemonConnection
    /// This app's bundle id: the daemon keeps the ledger under it and prefers its classic channel.
    public let bundleID: String

    public init(connection: DaemonConnection, bundleID: String) {
        self.connection = connection
        self.bundleID = bundleID
    }

    /// `classic_import.plan`: one run's decision (automatic only), source, plan and preview.
    /// `outline` leaves every terminal's scrollback out (a count or a folder list needs none).
    public func plan(_ mode: ClassicImportMode, outline: Bool = false) async throws -> ClassicImportReply {
        var fields: [String: JSONValue] = ["bundle_id": .string(bundleID), "mode": .string(mode.rawValue)]
        if outline { fields["outline"] = .bool(true) }
        let params = fields
        return try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "classic_import.plan", params: params, idempotencyKey: nil)
        }, as: ClassicImportReply.self, requiring: Self.capability)
    }

    /// `classic_import.record`: one ledger step, replayed by its idempotency key.
    @discardableResult
    public func record(_ event: ClassicImportEvent) async throws -> ClassicImportRecordResult {
        var fields: [String: JSONValue] = ["bundle_id": .string(bundleID)]
        fields.merge(event.fields) { _, new in new }
        let params = fields
        return try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "classic_import.record", params: params,
                                    idempotencyKey: UUID().uuidString.lowercased())
        }, as: ResourceMutationResult<ClassicImportRecordResult>.self, requiring: Self.capability).value
    }
}

/// Who started a run.
public enum ClassicImportMode: String, Sendable {
    /// At launch, by itself.
    case automatic
    /// Import Workspaces from Classic cmux.
    case manual
}

/// One `classic_import.record` step.
public enum ClassicImportEvent: Sendable {
    /// A launch's first contact with nothing to record.
    case seen
    /// A launch's first contact while this app was already in use: classic's workspaces recorded as seen, none made.
    case baseline
    /// The launch's preview was cancelled: later launches stop asking.
    case decline(source: JSONValue?)
    /// A confirmed run starts: the daemon backs up `backups` (classic's files read).
    case begin(source: JSONValue, backups: [String], cloudVMKeys: [String], appVersion: String?)
    case workspace(key: String, stage: Stage, nextWorkspace: String? = nil)
    case group(classic: String, next: String)
    case finish(source: JSONValue?, cloudVMKeys: [String], appVersion: String?)

    public enum Stage: String, Sendable { case pending, created, done, skipped }

    var fields: [String: JSONValue] {
        func texts(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
        var fields: [String: JSONValue]
        switch self {
        case .seen: fields = ["event": .string("seen")]
        case .baseline: fields = ["event": .string("baseline")]
        case .decline(let source): fields = ["event": .string("decline"), "source": source ?? .null]
        case .begin(let source, let backups, let keys, let version):
            fields = ["event": .string("begin"), "source": source, "backups": texts(backups), "cloud_vm_keys": texts(keys)]
            if let version { fields["app_version"] = .string(version) }
        case .workspace(let key, let stage, let next):
            fields = ["event": .string("workspace"), "key": .string(key), "stage": .string(stage.rawValue)]
            if let next { fields["next_workspace"] = .string(next) }
        case .group(let classic, let next):
            fields = ["event": .string("group"), "classic_group": .string(classic), "next_group": .string(next)]
        case .finish(let source, let keys, let version):
            fields = ["event": .string("finish"), "source": source ?? .null, "cloud_vm_keys": texts(keys)]
            if let version { fields["app_version"] = .string(version) }
        }
        return fields
    }
}

/// What `classic_import.record` left in the ledger.
public struct ClassicImportRecordResult: Decodable, Sendable {
    /// `inProgress` or `completed`; nil when there is no ledger.
    public var state: String?
    public var runs: Int
    /// Ledger entries (workspaces recorded).
    public var workspaces: Int
}

/// `classic_import.plan`'s reply.
public struct ClassicImportReply: Decodable, Sendable {
    /// What the ledger file held: `none` (first contact), `ledger`, `newer`, `unreadable` or `failed`.
    public var ledger: String
    /// Whether an automatic run starts; nil for a manual run.
    public var decision: Decision?
    /// The classic save read, echoed back by `begin` and `finish`; `bundleID` and `modifiedAt` name it.
    public var source: JSONValue?
    /// Classic's files the run read, for `begin` to back up.
    public var backups: [String]
    /// Why there is no plan (an unreadable save, a newer or unreadable ledger).
    public var error: String?
    public var plan: ClassicMigrationPlan?
    public var preview: Preview?
    /// Whether the classic app that saved `source` is open now and may still save.
    public var classicRunning: Bool

    enum CodingKeys: String, CodingKey {
        case ledger, decision, source, backups, error, plan, preview, classicRunning = "classic_running"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ledger = try container.decode(String.self, forKey: .ledger)
        decision = try container.decodeIfPresent(Decision.self, forKey: .decision)
        source = try container.decodeIfPresent(JSONValue.self, forKey: .source).flatMap { $0 == .null ? nil : $0 }
        backups = try container.decodeIfPresent([String].self, forKey: .backups) ?? []
        error = try container.decodeIfPresent(String.self, forKey: .error)
        plan = try container.decodeIfPresent(ClassicMigrationPlan.self, forKey: .plan)
        preview = try container.decodeIfPresent(Preview.self, forKey: .preview)
        classicRunning = try container.decodeIfPresent(Bool.self, forKey: .classicRunning) ?? false
    }

    /// The classic bundle id that saved `source`.
    public var sourceBundleID: String? { source?["bundleID"]?.stringValue }
    /// When classic saved `source` (seconds since 1970).
    public var savedAt: Double { source?["modifiedAt"]?.doubleValue ?? 0 }

    /// `{"decision": "first_run" | "resume" | "merge" | "skip", "reason": ...}`.
    public struct Decision: Decodable, Sendable, Equatable {
        public var decision: String
        /// Why it skips: `no_classic_session`, `unchanged`, `classic_running`, `ledger_not_usable`, `in_use_before`, `declined`.
        public var reason: String?

        public var skips: Bool { decision == "skip" }

        public init(decision: String, reason: String? = nil) {
            self.decision = decision
            self.reason = reason
        }
    }

    /// What the confirmation shows before a run writes anything.
    public struct Preview: Decodable, Sendable, Equatable {
        /// `stable`, `nightly`, `release_candidate`, `staging` or `debug`.
        public var channel: String
        public var workspaces: Int
        public var skippedCloudVMs: Int
        public var cleanupWorkspaces: Int
        public var browserTabs: Int
        public var localFilePages: Int
        public var sshWorkspaces: Int
        public var agentChats: Int

        public init(channel: String = "stable", workspaces: Int, skippedCloudVMs: Int = 0, cleanupWorkspaces: Int = 0, browserTabs: Int = 0,
                    localFilePages: Int = 0, sshWorkspaces: Int = 0, agentChats: Int = 0) {
            self.channel = channel
            self.workspaces = workspaces
            self.skippedCloudVMs = skippedCloudVMs
            self.cleanupWorkspaces = cleanupWorkspaces
            self.browserTabs = browserTabs
            self.localFilePages = localFilePages
            self.sshWorkspaces = sshWorkspaces
            self.agentChats = agentChats
        }

        enum CodingKeys: String, CodingKey {
            case channel, workspaces, skippedCloudVMs = "skipped_cloud_vms", cleanupWorkspaces = "cleanup_workspaces",
                 browserTabs = "browser_tabs", localFilePages = "local_file_pages", sshWorkspaces = "ssh_workspaces",
                 agentChats = "agent_chats"
        }
    }
}

/// What the confirmation shows: the daemon's preview of the exact plan, the classic
/// app it reads and when that saved, and whether that app is still open.
public struct ClassicImportPreview: Equatable, Sendable {
    public var counts: ClassicImportReply.Preview
    /// The classic bundle id whose save this imports.
    public var bundleID: String
    /// When classic saved it (seconds since 1970).
    public var savedAt: Double
    /// Whether that classic app is open now: this is its last autosave, not its quit save.
    public var classicRunning: Bool

    public init(counts: ClassicImportReply.Preview, bundleID: String, savedAt: Double, classicRunning: Bool) {
        self.counts = counts
        self.bundleID = bundleID
        self.savedAt = savedAt
        self.classicRunning = classicRunning
    }

    public init(reply: ClassicImportReply) {
        self.init(counts: reply.preview ?? ClassicImportReply.Preview(workspaces: reply.plan?.workspaces.count ?? 0),
                  bundleID: reply.sourceBundleID ?? "com.cmuxterm.app", savedAt: reply.savedAt, classicRunning: reply.classicRunning)
    }
}

/// What one run makes, as the daemon planned it.
public struct ClassicMigrationPlan: Decodable, Sendable, Equatable {
    public var windows: [Window]
    public var groups: [Group]
    /// Workspaces a cut-off run left half made: closed before they are made again.
    public var cleanup: [String]
    /// Why each classic workspace left out stays: `already_migrated`, `duplicate` or `cloud_vm`.
    public var skipped: [String: String]

    /// One classic window's workspaces that come over, in sidebar order.
    public struct Window: Decodable, Sendable, Equatable {
        public var frame: CGRect?
        public var selectedKey: String?
        public var workspaces: [ClassicSessionWorkspace]

        enum CodingKeys: String, CodingKey { case frame, selectedKey = "selected_key", workspaces }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            frame = try container.decodeIfPresent(Rect.self, forKey: .frame).map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            selectedKey = try container.decodeIfPresent(String.self, forKey: .selectedKey)
            workspaces = try container.decode([ClassicSessionWorkspace].self, forKey: .workspaces)
        }

        private struct Rect: Decodable { var x, y, width, height: Double }
    }

    /// A classic group the run needs; `existing` is the group an earlier run made, nil makes one.
    public struct Group: Decodable, Sendable, Equatable {
        public var classic: ClassicSessionGroup
        public var existing: String?
    }

    /// Every workspace that comes over, window after window.
    public var workspaces: [ClassicSessionWorkspace] { windows.flatMap(\.workspaces) }
    /// Whether the run has nothing to make.
    public var isEmpty: Bool { windows.isEmpty && groups.allSatisfy { $0.existing != nil } && cleanup.isEmpty }
    /// The Cloud VM workspaces it leaves, recorded as skipped.
    public var cloudVMKeys: [String] { skipped.filter { $0.value == "cloud_vm" }.map(\.key).sorted() }
    public var alreadyMigrated: Int { skipped.values.count { $0 == "already_migrated" } }
}

/// A sidebar group of a classic window.
public struct ClassicSessionGroup: Decodable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var collapsed: Bool
    public var pinned: Bool
    public var color: String?
    public var icon: String?
}

/// One classic workspace.
public struct ClassicSessionWorkspace: Decodable, Sendable, Equatable {
    public var name: String
    public var workingDirectory: String
    public var layout: ClassicSessionLayout
    /// The SSH host its terminals ran on; nil for a local workspace.
    public var remote: ClassicSessionRemote?
    public var cloudVM: String?
    /// Whether it had panels that do not come over (markdown, file preview).
    public var leftOutPanels: Bool
    /// Classic's identity across saves; the ledger keys on it.
    public var key: String
    public var color: String?
    public var pinned: Bool
    public var groupID: String?

    enum CodingKeys: String, CodingKey {
        case name, workingDirectory = "working_directory", layout, remote, cloudVM = "cloud_vm",
             leftOutPanels = "left_out_panels", key, color, pinned, groupID = "group_id"
    }
}

/// Where a classic SSH workspace ran.
public struct ClassicSessionRemote: Decodable, Sendable, Equatable {
    public var destination: String
    public var port: Int?

    /// `[user@]host[:port]`, an IPv6 host in brackets, port 22 left out (`Remote::ssh_destination`).
    public var sshDestination: String {
        let parts = destination.split(separator: "@", omittingEmptySubsequences: false)
        let user = parts.count > 1 ? parts.dropLast().joined(separator: "@") + "@" : ""
        var host = parts.last.map(String.init) ?? destination
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        guard let port, port != 22 else { return user + host }
        return "\(user)\(host):\(port)"
    }
}

/// A Claude Code or Codex session classic recorded on a terminal.
public struct ClassicSessionAgent: Decodable, Sendable, Equatable {
    public var harness: String
    public var sessionID: String
    public var workingDirectory: String?

    enum CodingKeys: String, CodingKey { case harness, sessionID = "session_id", workingDirectory = "working_directory" }
}

/// A terminal or browser tab.
public struct ClassicSessionTab: Decodable, Sendable, Equatable {
    public var workingDirectory: String?
    public var title: String?
    /// A browser tab's page; nil for a terminal.
    public var url: String?
    public var agent: ClassicSessionAgent?
    /// What the terminal prints once above its first prompt: classic's scrollback, already
    /// cut to classic's limits and stripped to text and color by the daemon.
    public var scrollback: String?

    enum CodingKeys: String, CodingKey { case workingDirectory = "working_directory", title, url, agent, scrollback }
}

/// A pane and its tabs.
public struct ClassicSessionPane: Decodable, Sendable, Equatable {
    public var tabs: [ClassicSessionTab]
    public var selectedTab: Int

    enum CodingKeys: String, CodingKey { case tabs, selectedTab = "selected_tab" }
}

/// The classic split tree: `{"pane": {...}}` or `{"split": {orientation, ratio, first, second}}`.
public indirect enum ClassicSessionLayout: Decodable, Sendable, Equatable {
    case pane(ClassicSessionPane)
    case split(orientation: Orientation, ratio: Double, first: ClassicSessionLayout, second: ClassicSessionLayout)

    public enum Orientation: String, Decodable, Sendable { case horizontal, vertical }

    enum CodingKeys: String, CodingKey { case pane, split }
    private struct Split: Decodable {
        var orientation: Orientation
        var ratio: Double
        var first: ClassicSessionLayout
        var second: ClassicSessionLayout
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let pane = try container.decodeIfPresent(ClassicSessionPane.self, forKey: .pane) {
            self = .pane(pane)
        } else {
            let split = try container.decode(Split.self, forKey: .split)
            self = .split(orientation: split.orientation, ratio: split.ratio, first: split.first, second: split.second)
        }
    }

    /// The tree with only the tabs `keep` accepts; a side left with none closes up. Nil when none is kept.
    public func keeping(_ keep: (ClassicSessionTab) -> Bool) -> ClassicSessionLayout? {
        switch self {
        case .pane(let pane):
            let tabs = pane.tabs.filter(keep)
            guard !tabs.isEmpty else { return nil }
            let selected = pane.tabs.dropFirst(pane.selectedTab).first
            return .pane(ClassicSessionPane(tabs: tabs, selectedTab: selected.flatMap { tabs.firstIndex(of: $0) } ?? 0))
        case .split(let orientation, let ratio, let first, let second):
            switch (first.keeping(keep), second.keeping(keep)) {
            case (let a?, let b?): return .split(orientation: orientation, ratio: ratio, first: a, second: b)
            case (let a, let b): return a ?? b
            }
        }
    }

    /// Tabs in pane order, first side first.
    public var tabs: [ClassicSessionTab] {
        switch self {
        case .pane(let pane): pane.tabs
        case .split(_, _, let first, let second): first.tabs + second.tabs
        }
    }
}
