import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextPages
import CmuxNextSettings
import Foundation

// `debug.terminal.links` (DEBUG builds), for scripts/cmux-next/terminal-path-links-live.py:
// `open` activates a link text in the focused terminal as a Cmd-click on it does, and the
// reply lists where terminal links went since the last `clear` (recording builds,
// `CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS=1`, record a link for another app instead of opening it).
enum DebugTerminalLinks {
    static func register(on router: ControlRouter?, services: AppServices) {
        #if DEBUG
        router?.register([
            .mainActor("debug.terminal.links") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(handle(call.params, services: services))
            },
        ])
        #endif
    }
}

#if DEBUG
extension DebugTerminalLinks {
    /// `{open?, hover?, click?, keys?, modifiers?, tab?, menu?, route?, other?, agentLink?, clear?}`: `tab` (a layout tab id)
    /// is the terminal `open` clicks in, else the focused one. `hover: [column, row]` moves the pointer over that viewport
    /// cell and `click: [column, row]` clicks there, both through the view's own mouse handlers with `keys` held
    /// (`["command"]` by default; `[]` for none); `modifiers: [...]` presses or releases keys with the pointer still.
    /// `hovered` is the link Ghostty reports under the pointer (`link-previews`), `wrapped` a link cmux found that
    /// Ghostty does not (a URL a program broke onto rows, a bare file name), `underlinedRows` the rows cmux underlines
    /// for it, `pointingHand` whether the pointer shows the hand. `menu` (text, or true for
    /// the hovered link) returns the right-click's link or path rows; `route` where a click on that URL goes now
    /// (`other`: Shift-Command), opening nothing; `agentLink` opens a URL as a click in an agent chat does.
    /// `opened` is where links went (``LinkRouter/recorded``).
    static func handle(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        var result: [String: JSONValue] = [:]
        if let text = params["open"]?.stringValue {
            guard let entry = terminal(params, services: services) else { return .object(["error": .string("no terminal")]) }
            result["handled"] = .bool(entry.session.activateLink(text))
            result["tab"] = services.cache.tabKey(for: entry.session).map(JSONValue.string) ?? .null
        }
        if let cell = params["hover"]?.arrayValue, cell.count == 2, let column = cell[0].intValue, let row = cell[1].intValue {
            guard let entry = terminal(params, services: services) else { return .object(["error": .string("no terminal")]) }
            entry.session.hoverLinkForTesting(column: column, row: row, flags: keys(params["keys"]))
        }
        if let held = params["modifiers"] {
            guard let entry = terminal(params, services: services) else { return .object(["error": .string("no terminal")]) }
            entry.session.modifiersChangedForTesting(keys(held))
        }
        if let cell = params["click"]?.arrayValue, cell.count == 2, let column = cell[0].intValue, let row = cell[1].intValue {
            guard let entry = terminal(params, services: services) else { return .object(["error": .string("no terminal")]) }
            entry.session.clickLinkForTesting(column: column, row: row, flags: keys(params["keys"]))
        }
        if let entry = terminal(params, services: services) {
            result["hovered"] = entry.session.model.hoveredLink.map(JSONValue.string) ?? .null
            let pointer = entry.session.linkPointerStateForTesting
            result["wrapped"] = pointer.wrapped.map(JSONValue.string) ?? .null
            result["underlinedRows"] = .array(pointer.underlinedRows.map { JSONValue($0) })
            result["pointingHand"] = .bool(pointer.pointingHand)
            if let menu = params["menu"], menu.boolValue == true || menu.stringValue != nil {
                let rows = services.terminalDelegate.linkMenu(entry.session, text: menu.stringValue, services: services).rows
                result["menu"] = .array(rows.map(\.json))
            }
        }
        if let url = params["route"]?.stringValue.flatMap(URL.init(string:)) {
            result["route"] = .string(LinkRouter.shared.target(for: url, otherTarget: params["other"]?.boolValue == true).rawValue)
        }
        if let url = params["agentLink"]?.stringValue.flatMap(URL.init(string:)) { result["agentOpened"] = .bool(AgentPaneView.debugOpenClickedLink(url)) }
        result["opened"] = .array(LinkRouter.shared.recorded.map(JSONValue.string))
        if params["clear"]?.boolValue == true { LinkRouter.shared.recorded.removeAll() }
        return .object(result)
    }

    /// `["command", "shift", "option", "control"]` as modifier flags; Command alone when absent.
    static func keys(_ value: JSONValue?) -> NSEvent.ModifierFlags {
        guard let names = value?.arrayValue else { return .command }
        var flags: NSEvent.ModifierFlags = []
        for name in names.compactMap(\.stringValue) {
            switch name {
            case "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option": flags.insert(.option)
            case "control": flags.insert(.control)
            default: break
            }
        }
        return flags
    }

    static func terminal(_ params: [String: JSONValue], services: AppServices) -> TerminalEntry? {
        if let id = params["tab"]?.stringValue { return services.cache.existingTerminal(id) }
        guard case .terminal(let focused)? = ActionScope(services: services, invocation: ActionInvocation()).pane?.currentContent else {
            return nil
        }
        return focused
    }
}
#endif
