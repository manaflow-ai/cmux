import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextLayout

/// Scratch diagnostics for the triage of three CmuxNextAppTests failures (never merged).
@MainActor enum T3DiagDump {
    static func lone(_ pane: PaneController, _ services: AppServices) -> String {
        let resolved = ChatColumnPlacement.resolve(from: pane, services: services)
        let dockRole = pane.workspace?.daemon.supports(DaemonCapability.dockColumnRole.rawValue)
        let chats = pane.pane.tabs.map { ChatColumnPlacement.isChat($0, services: services) }
        return "resolve=\(resolved) dockRole=\(String(describing: dockRole)) isChat=\(chats)"
    }

    static func layout(_ content: WorkspaceContentController?) -> String {
        guard let content else { return "no content" }
        let screens = content.layoutModel.screens.map { screen in
            "screen cols=" + screen.layout.columns.map { column in
                "[\(column.root.panes.map(\.rawValue)) dock=\(column.dock.map { "role=\(String(describing: $0.role)) pinned=\($0.isPinned) tabs=\($0.allowsTabs)" } ?? "nil")]"
            }.joined(separator: " ")
        }
        let panes = content.panes.values.map { pane in
            "\(pane.layoutPaneID.rawValue)\(pane === content.focusedPane ? "*" : ""): w=\(Int(pane.view.frame.width)) tabs=\(pane.pane.tabs.map { "\($0.id)/\($0.kind)/session=\($0.agentSession != nil)" })"
        }.sorted()
        let window = content.contentView.window.map { "window=\(Int($0.frame.width))x\(Int($0.frame.height)) screen=\($0.screen.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "nil")" } ?? "no window"
        return "\(window) \(screens.joined(separator: "; ")) panes: \(panes.joined(separator: "; ")) gen=\(content.focus.state.generation)"
    }
}
