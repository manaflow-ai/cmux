public import CmuxNextPages
public import CmuxNextSettings
public import CmuxNextSidebar
public import Foundation

/// Settings > Sidebar > Archived Workspaces (cmux#51635, like ChatGPT's Settings > Data controls > Archived chats):
/// the sidebar draws no archived row (`SidebarLayout+ArchiveSection`), so this card is where a person finds them.
/// `cmux.settings.archived.list` answers `{available, rows}` (``SidebarArchivedList``, in sidebar order);
/// `cmux.settings.archived.run {action, kind, id}` opens, restores or deletes one and answers `{error?}`.
/// Restore is the document's `unarchive` (an archived group restores with its member, one undo step); Delete is
/// the sidebar's own Close Workspace (it asks about a running program) or Remove of a link row. Only the Settings
/// page itself may run them.
@MainActor
public final class SettingsArchivedWorkspaces: PageProvider {
    public static let listOp = "cmux.settings.archived.list"
    public static let runOp = "cmux.settings.archived.run"
    public enum Action: String, Sendable { case open, restore, delete }

    /// What the card reads and runs: the App's sidebar (``host(_:)``) or a test's.
    public struct Host {
        /// The archived rows, nil before a window's sidebar is up.
        public var entries: @MainActor () -> [SidebarArchivedEntry]?
        /// Runs `action` on `entry`; a refusal's text, or nil when it ran.
        public var run: @MainActor (Action, SidebarArchivedEntry) -> String?

        public init(entries: @escaping @MainActor () -> [SidebarArchivedEntry]?,
                    run: @escaping @MainActor (Action, SidebarArchivedEntry) -> String?) {
            (self.entries, self.run) = (entries, run)
        }
    }

    private let host: Host
    private let personOnly: String

    /// `personOnly`: the refusal another page's script reads.
    public init(host: Host, personOnly: String) {
        (self.host, self.personOnly) = (host, personOnly)
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.listOp:
            guard let entries = host.entries() else { return ["available": false] }
            return ["available": true, "rows": .array(entries.map(Self.json))]
        case Self.runOp:
            // A person's click on a row's button in Settings, never a script (another page's, or one in Settings).
            guard context.page == PageDescriptor.settings.id, context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: personOnly)
            }
            guard let action = params["action"]?.stringValue.flatMap(Action.init(rawValue:)),
                  let kind = params["kind"]?.stringValue.flatMap(SidebarArchivedEntry.Kind.init(rawValue:)),
                  let id = params["id"]?.stringValue, !id.isEmpty else {
                throw PageError.invalidParams("action (open, restore or delete), kind (workspace or item) and id are required")
            }
            // Only a row the list shows: the page names no other workspace.
            guard let entry = host.entries()?.first(where: { $0.kind == kind && $0.id == id }) else {
                throw PageError.invalidParams("no archived \(kind.rawValue) \(id)")
            }
            return host.run(action, entry).map { ["error": .string($0)] } ?? .object([:])
        default:
            throw PageError.unknownOp(op)
        }
    }

    static func json(_ entry: SidebarArchivedEntry) -> JSONValue {
        ["kind": .string(entry.kind.rawValue), "id": .string(entry.id), "title": .string(entry.title),
         "group": entry.group.map(JSONValue.string) ?? .null, "machine": entry.machine.map(JSONValue.string) ?? .null]
    }
}

extension SettingsArchivedWorkspaces.Host {
    /// The App's archived rows and their actions, through its ``SidebarArchiveHost``.
    public static func host(_ host: any SidebarArchiveHost) -> Self {
        Self(
            entries: { [weak host] in host?.archiveSections.map(SidebarArchivedList.entries(in:)) },
            run: { [weak host] action, entry in
                guard let host else { return nil }
                switch action {
                case .open: host.archiveOpen(entry); return nil
                case .restore: return restore(entry, host)
                case .delete: return host.archiveDelete(entry)
                }
            })
    }

    /// Unarchive, not the menu's toggle: a member of an archived group carries no mark of its own, and the reducer's
    /// `unarchive` restores the groups that hold it with it.
    @MainActor private static func restore(_ entry: SidebarArchivedEntry, _ host: any SidebarArchiveHost) -> String? {
        let item = entry.kind == .workspace ? host.archiveItem(workspace: entry.id) : entry.id
        guard let store = host.archiveDocument, store.isActive, let item else { return ArchiveStrings.needsDocument }
        do {
            try store.setArchived([item], archived: false,
                                  title: entry.kind == .workspace ? ArchiveStrings.unarchiveWorkspace : ArchiveStrings.unarchiveItem)
        } catch {
            return host.archiveRefusal(error)
        }
        return nil
    }
}
