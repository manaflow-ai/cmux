public import CmuxNextActions
public import CmuxNextSidebar

/// Archive Settled Chats (`workspace.archiveSettled`): every settled chat the active window's sidebar lists (a seen,
/// finished chat, by the Rust rule `SidebarSettlePlanner` reaches) archives as one undo step, with the toast's Undo
/// (``AutoArchiveCoordinator/archive(workspaces:)``). Archiving keeps each chat's history and its session reattaches.
/// It never archives on a badge alone: an unread answer, a failed turn, a lost agent, a working chat or one waiting
/// for an answer stays where it is, and so does the window's current chat. With none settled the action is disabled
/// with that reason, and a run from the palette, the CLI or MCP is refused with it.
@MainActor
public struct SidebarArchiveSettledAction {
    public static let id: ActionID = "workspace.archiveSettled"

    private let coordinator: AutoArchiveCoordinator
    private let sidebar: @MainActor () -> SidebarView?

    /// - Parameters:
    ///   - coordinator: Archives the chats as one undo step and shows the toast.
    ///   - sidebar: The active window's sidebar, whose listed rows the rule reads; nil with no window.
    public init(coordinator: AutoArchiveCoordinator, sidebar: @escaping @MainActor () -> SidebarView?) {
        self.coordinator = coordinator
        self.sidebar = sidebar
    }

    public func bind(into registry: ActionRegistry) {
        let settled = self.settled
        let coordinator = coordinator
        registry.bindEffect(Self.id, unavailable: { nil }, effect: { _ in
            guard let ids = settled() else { return .refused(Self.noWindow) }
            do throws(AutoArchiveRefusal) {
                return try coordinator.archive(workspaces: ids) == 0 ? .refused(Self.noneSettled) : .done
            } catch {
                return .refused(error.message)
            }
        })
        ActionTargetReasons.set(Self.id, in: registry) { _ in
            guard let ids = settled() else { return Self.noWindow }
            return coordinator.archivableItems(workspaces: ids).isEmpty ? Self.noneSettled : nil
        }
    }

    /// The workspace ids of the settled chats to archive, the window's current one aside; nil with no window.
    private func settled() -> [String]? {
        guard let model = sidebar()?.model else { return nil }
        let active = model.activeWorkspaceID
        return model.settleArchivePlan().archive.filter { $0 != active }.map(\.rawValue)
    }

    static var noneSettled: String {
        text("archive.refusal.noSettledChats",
             "There are no settled chats to archive. Unread answers, failed turns and lost agents stay until you look at them.")
    }
    static var noWindow: String { String(localized: "reveal.refusal.noWindow", defaultValue: "no window is open", table: "SidebarReveal", bundle: .localizedModule) }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "SidebarArchive", bundle: .localizedModule)
    }
}
