import CmuxNextActions
import CmuxNextBridge
import CmuxNextLayout
import Foundation
import Observation

/// Where a person's new terminal goes when it is opened from an agent chat
/// (lawrence-call-1006 D, two columns like the Codex app): never into the
/// chat's column. The chat stays alone, docked on the left, and tools are
/// tabs in the column beside it.
enum ChatColumnPlacement: Equatable {
    /// A tab in the pane it was opened from: the pane is not in a chat column.
    case here
    /// A tab in this pane, outside the chat's column.
    case tab(in: LayoutPaneID)
    /// The chat's column is the screen's only scrolling one: a new column
    /// right of it, then the chat's column docks on the left.
    case newColumnDockingChat(LayoutColumnID)

    /// `columns` are the screen's, in strip order; `isChatColumn` says
    /// whether a column holds only agent chats; `recent` orders panes by
    /// last focus, newest first. A docked chat sends the tool to the first
    /// scrolling column; an undocked one to the scrolling column on its
    /// right, else the nearest on its left. In that column, the pane
    /// focused last gets the tab.
    static func resolve(from pane: LayoutPaneID, columns: [LayoutColumn], recent: [LayoutPaneID] = [],
                        isChatColumn: (LayoutColumn) -> Bool) -> ChatColumnPlacement {
        guard let index = columns.firstIndex(where: { $0.root.contains(pane) }), isChatColumn(columns[index]) else { return .here }
        let scrolling = columns.indices.filter { $0 != index && columns[$0].dock == nil }
        let target: Int?
        if columns[index].dock != nil {
            target = scrolling.first
        } else {
            guard !scrolling.isEmpty else { return .newColumnDockingChat(columns[index].id) }
            target = scrolling.first { $0 > index } ?? scrolling.last { $0 < index }
        }
        guard let target else { return .here }
        let root = columns[target].root
        guard let pane = recent.first(where: root.contains) ?? root.panes.first else { return .here }
        return .tab(in: pane)
    }
}

extension ChatColumnPlacement {
    /// A person's New Terminal from a pane of a chat column: a tab beside
    /// the chat (``resolve(from:columns:recent:isChatColumn:)``), focused.
    /// False when it belongs in `pane` after all.
    @MainActor static func openTerminal(from pane: PaneController, cwd: String?, keep: Bool?, services: AppServices) -> Bool {
        guard let content = pane.workspace, let screen = content.layoutModel.screen(containing: pane.layoutPaneID) else { return false }
        // A screen stored as one split tree is one implicit column.
        let columns = screen.layout.columns.isEmpty ? screen.column(containing: pane.layoutPaneID).map { [$0] } ?? []
            : screen.layout.columns
        let tabs = services.agentTabs
        let placement = resolve(from: pane.layoutPaneID, columns: columns, recent: content.recentPanes) { column in
            column.root.panes.allSatisfy { id in
                guard let tabsOfPane = content.panes[id]?.pane.tabs, !tabsOfPane.isEmpty else { return false }
                return tabsOfPane.allSatisfy { tabs.isAgentTab($0.id) }
            }
        }
        switch placement {
        case .here:
            return false
        case .tab(let target):
            guard let controller = content.panes[target] else { return false }
            controller.newTerminalTab(cwd: cwd, keep: keep, fromSelectedTab: true)
            PaneHandlers.focus(target, in: content)
            return true
        case .newColumnDockingChat:
            // The new column's terminal starts in the chat's cwd and takes focus.
            content.layoutModel.newColumn(after: pane.layoutPaneID)
            let chat = pane.layoutPaneID
            services.registry.track(Task { @MainActor in
                // The chat's column has a real id only once the daemon's
                // snapshot shows the new column beside it.
                let column = try? await ControlDeadline.shared.run(method: "chat.dockLeft", deadline: .now + .seconds(10)) { @MainActor in
                    await dockableColumn(of: chat, in: content)
                }
                guard let column else { return ActionWorkFailure("chat column: the new column did not appear") }
                do {
                    try ColumnDocking.apply(DockColumn(edge: .left, mode: ColumnDocking.defaultMode), to: column, in: content)
                } catch {
                    return ActionWorkFailure("chat column: \(error)")
                }
                return nil
            })
            return true
        }
    }

    /// The column holding `chat` once its screen has another scrolling column.
    @MainActor private static func dockableColumn(of chat: LayoutPaneID, in content: WorkspaceContentController) async -> LayoutColumn? {
        func current() -> LayoutColumn? {
            guard let layout = content.layoutModel.screen(containing: chat)?.layout,
                  let column = layout.column(containing: chat),
                  layout.columns.contains(where: { $0.id != column.id && $0.dock == nil }) else { return nil }
            return column
        }
        if let column = current() { return column }
        for await ready in Observations({ current() != nil }) where ready { return current() }
        return nil
    }
}
