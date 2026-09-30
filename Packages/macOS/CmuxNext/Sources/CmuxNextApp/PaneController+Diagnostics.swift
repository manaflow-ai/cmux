import AppKit
import CmuxNextSettings
import CmuxNextTerminal

/// One pane's surface state for `debug.surfaces` and the blank-pane invariant.
struct PaneSurfaceStatus {
    var paneKey: String
    var isVisible: Bool
    var selectedTab: String?
    var shownTab: String?
    var kind: String
    var contentInstalled: Bool
    var contentInWindow: Bool
    var contentSize: CGSize
    var terminal: TerminalSurfaceDiagnostics?

    /// A visible pane with a selected tab that shows nothing usable.
    var isBlank: Bool {
        guard isVisible, selectedTab != nil else { return false }
        guard selectedTab == shownTab, contentInstalled, contentInWindow,
              contentSize.width >= 1, contentSize.height >= 1 else { return true }
        if let terminal { return !terminal.isPresentable }
        return false
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "pane": .string(paneKey),
            "visible": .bool(isVisible),
            "selected_tab": selectedTab.map(JSONValue.string) ?? .null,
            "shown_tab": shownTab.map(JSONValue.string) ?? .null,
            "kind": .string(kind),
            "content_installed": .bool(contentInstalled),
            "content_in_window": .bool(contentInWindow),
            "content_size": .string("\(Int(contentSize.width))x\(Int(contentSize.height))"),
            "blank": .bool(isBlank),
        ]
        if let terminal {
            object["surface"] = [
                "exists": .bool(terminal.hasSurface),
                "replay_applied": .bool(terminal.hasContent),
                "rendering_suspended": .bool(terminal.renderingSuspended),
                "drawing": terminal.drawing.map(JSONValue.bool) ?? .null,
                "grid": terminal.grid.map { .string("\($0.columns)x\($0.rows)") } ?? .null,
                "in_host": .bool(terminal.surfaceInHost),
                "in_window": .bool(terminal.inWindow),
                "hidden": .bool(terminal.hidden),
                "view_size": .string("\(Int(terminal.viewSize.width))x\(Int(terminal.viewSize.height))"),
                "layer_size": .string("\(Int(terminal.layerSize.width))x\(Int(terminal.layerSize.height))"),
            ]
        }
        return .object(object)
    }
}

extension PaneController {
    /// Reads the pane's live state without creating any surface.
    var surfaceStatus: PaneSurfaceStatus {
        let content = currentTabKey.flatMap(existingContent(for:))
        let view = content?.view
        var terminal: TerminalSurfaceDiagnostics?
        var kind = "none"
        switch content {
        case .terminal(let entry):
            kind = "terminal"
            terminal = entry.session.diagnostics
        case .browser:
            kind = "browser"
        case nil:
            break
        }
        let installed = view != nil && self.view.content === view && self.view.hostsContent
        return PaneSurfaceStatus(
            paneKey: paneKey,
            isVisible: isVisible,
            selectedTab: stripModel.selectedID?.rawValue,
            shownTab: currentTabKey,
            kind: kind,
            contentInstalled: installed,
            contentInWindow: view?.window != nil,
            contentSize: view?.bounds.size ?? .zero,
            terminal: terminal
        )
    }
}
