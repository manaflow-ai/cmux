public import CmuxNextActions
public import CmuxNextSidebar

/// A project's own Chats per Project (Leo 2026-11-10: "a per-project override in the right-click menu"):
/// `workspaceGroup.setRowLimit` stores it on the group in the home daemon's sidebar document (`extra.row_limit`),
/// one undo step. Default follows the `sidebar.chatsPerProject` setting, All never folds; the group menu's
/// Options > Chats per Project shows the choices with the group's own checked, and the palette, the CLI and MCP run it.
@MainActor
public final class SidebarGroupRowLimitActions {
    private let host: any SidebarArchiveHost
    private let store: @MainActor () -> SidebarDocStore?

    /// - Parameter host: names the invocation's group and gives the sidebar document (the archive actions' host).
    public init(host: any SidebarArchiveHost) {
        self.host = host
        store = { [weak host] in host?.archiveDocument }
    }

    public func bind(into registry: ActionRegistry) {
        let unavailable: @MainActor () -> String? = { [self] in self.activeStore() == nil ? ArchiveStrings.groupRowLimitNeedsDocument : nil }
        registry.bindEffect("workspaceGroup.setRowLimit", unavailable: unavailable, effect: { [self] invocation in
            guard let store = self.activeStore() else { return .refused(ArchiveStrings.groupRowLimitNeedsDocument) }
            // A string from the menu, the palette and the CLI; MCP may send the count as a number.
            guard let value = invocation["limit"]?.stringValue ?? invocation["limit"]?.intValue.map(String.init), let cap = Self.cap(value) else {
                return .refused(ArchiveStrings.groupRowLimitBadValue)
            }
            do {
                try store.setGroupRowLimit(self.group(invocation, in: store), cap.limit)
                return .done
            } catch let refusal as SidebarDocSendRefusal {
                return .refused(refusal.message)
            } catch {
                return .refused(self.host.archiveRefusal(error))
            }
        })
        // The choices check the group's own cap: Default when it follows the setting.
        ActionTargetTitles.setChoiceState("workspaceGroup.setRowLimit", in: registry) { [self] target in
            guard let store = self.activeStore(), let group = try? self.group(ActionInvocation(target: target), in: store) else { return nil }
            return Self.value(store.groupRowLimit(group))
        }
    }

    /// A choice's cap: `default` is nil (the setting), `all` is 0, a count above 0 is itself; nil for anything else.
    nonisolated static func cap(_ value: String) -> Cap? {
        switch value {
        case "default": return Cap(limit: nil)
        case "all": return Cap(limit: 0)
        default:
            guard let count = Int(value), count > 0 else { return nil }
            return Cap(limit: count)
        }
    }

    /// A parsed choice: the store's cap (nil follows the setting, 0 is All).
    nonisolated struct Cap: Equatable, Sendable {
        var limit: Int?
    }

    /// The choice a stored cap reads as: the inverse of `cap`.
    nonisolated static func value(_ limit: Int?) -> String {
        guard let limit else { return "default" }
        return limit == 0 ? "all" : String(limit)
    }

    /// The invocation's group: a personal group by id or name, else a group target the document holds (a nested
    /// group made in the sidebar has no personal row; the editor names it by its document item).
    private func group(_ invocation: ActionInvocation, in store: SidebarDocStore) throws -> GroupID {
        do {
            return try GroupID(host.archiveGroupID(invocation))
        } catch {
            guard let target = invocation.target, target.kind == .workspaceGroup, store.records.items[target.id]?.body.isGroup == true else { throw error }
            return GroupID(target.id)
        }
    }

    private func activeStore() -> SidebarDocStore? { store().flatMap { $0.isActive ? $0 : nil } }
}
