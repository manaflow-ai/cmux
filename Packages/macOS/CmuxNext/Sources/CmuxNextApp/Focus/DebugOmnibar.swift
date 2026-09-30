import AppKit
import CmuxNextBrowser
import CmuxNextSettings

/// `debug.omnibar` and (DEBUG builds) `debug.mouse`: the omnibar of a
/// browser pane (default: the focused pane of the first window, or of
/// `window`). `debug.omnibar` reports the state machine next to what the
/// field editor shows; `debug.mouse` presses, drags and releases over the
/// omnibar text as AppKit would for a key window, without activating the
/// app or making the window key (plans/cmux-next/focus.md, section 7).
enum DebugOmnibar {
    static func report(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let bar = addressBar(params, services: services) else { return .object(["error": .string("no browser pane")]) }
        let snapshot = bar.debugSnapshot
        func range(_ value: NSRange?) -> JSONValue {
            guard let value else { return .null }
            return .array([.number(Double(value.location)), .number(Double(value.length))])
        }
        return .object([
            "phase": .string(snapshot.phase),
            "has_focus": .bool(snapshot.hasFocus),
            "elided": .bool(snapshot.elided),
            "text": .string(snapshot.text),
            "selection": range(snapshot.selection),
            "field_text": .string(snapshot.fieldText),
            "field_selection": range(snapshot.fieldSelection),
            "field_editor_active": .bool(snapshot.fieldEditorActive),
            "rows": .array(snapshot.rows.map(JSONValue.string)),
            "highlighted": snapshot.highlighted.map { .number(Double($0)) } ?? .null,
            "copy_text": snapshot.copyText.map(JSONValue.string) ?? .null,
            "consistent": .bool(!snapshot.fieldEditorActive || (snapshot.text == snapshot.fieldText && snapshot.selection == snapshot.fieldSelection)),
        ])
    }

    #if DEBUG
    /// Params: `character` (index the press lands on), optional `drag_to`,
    /// `click_count` (1-3), `button` (`left` or `right`; a right-click skips
    /// the context menu), `pane`, `window`.
    static func mouse(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let bar = addressBar(params, services: services) else { return .object(["error": .string("no browser pane")]) }
        let gesture = OmnibarDebugMouse(
            character: params["character"]?.intValue ?? 0,
            dragTo: params["drag_to"]?.intValue,
            clickCount: min(max(params["click_count"]?.intValue ?? 1, 1), 3),
            button: params["button"]?.stringValue == "right" ? .right : .left
        )
        if let error = bar.debugMouse(gesture) { return .object(["error": .string(error)]) }
        return report(params, services: services)
    }
    #endif

    private static func addressBar(_ params: [String: JSONValue], services: AppServices) -> AddressBarView? {
        let windowID = params["window"]?.stringValue
        guard let controller = services.windows.controllers.first(where: { windowID == nil || $0.state.id == windowID }),
              let pane = params["pane"]?.stringValue ?? controller.focus.state.pane,
              let paneController = controller.content?.paneController(key: pane),
              case .browser(let entry)? = paneController.currentContent else { return nil }
        return entry.chrome.addressBar
    }
}
