import AppKit
import CmuxNextBrowser
import CmuxNextSettings

/// `debug.omnibar` and (DEBUG builds) `debug.mouse` and
/// `debug.omnibar_type`: the omnibar of a
/// browser pane (default: the focused pane of the first window, or of
/// `window`). `debug.omnibar` reports the state machine next to what the
/// field editor shows; `debug.mouse` presses, drags and releases over the
/// omnibar text as AppKit would for a key window, without activating the
/// app or making the window key (plans/cmux-next/focus.md, section 7);
/// `debug.omnibar_type` types text and presses Return in the field the same way.
enum DebugOmnibar {
    static func report(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let bar = addressBar(params, services: services) else { return .object(["error": .string("no browser pane")]) }
        // `press_row`: press that suggestion row (its click path) before the report.
        var pressed: JSONValue = .null
        if let row = params["press_row"]?.intValue { pressed = .bool(bar.debugPressRow(row)) }
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
            "profile_badge": bar.profileBadgeName.map(JSONValue.string) ?? .null,
            "consistent": .bool(!snapshot.fieldEditorActive || (snapshot.text == snapshot.fieldText && snapshot.selection == snapshot.fieldSelection)),
            "pressed_row": pressed,
            "card": bar.debugCard.map { card in
                .object([
                    "pane_layer": .bool(card.paneLayer), "flush_under_bar": .bool(card.isFlushUnderBar),
                    "card_in_window": rect(card.cardInWindow), "bar_in_window": rect(card.barInWindow),
                    "row_kinds": .array(card.rowKinds.map(JSONValue.string)),
                ])
            } ?? .null,
        ])
    }

    private static func rect(_ rect: NSRect) -> JSONValue {
        .array([rect.minX, rect.minY, rect.width, rect.height].map { .number(Double($0)) })
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

    /// `debug.omnibar_type`. Params: `text`, `commit` (default true),
    /// `pane`, `window`. Focuses the omnibar, types `text` through its field
    /// editor and presses Return there (`AddressBarView.debugTypeAndCommit`):
    /// the path typed keys take once they reach the field, without
    /// activating the app or making the window key. Reports the omnibar
    /// after, plus `typed` (false when the field did not start editing).
    static func type(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let text = params["text"]?.stringValue else { return .object(["error": .string("text is required")]) }
        guard let bar = addressBar(params, services: services) else { return .object(["error": .string("no browser pane")]) }
        let typed = bar.debugTypeAndCommit(text, commit: params["commit"]?.boolValue ?? true)
        guard case .object(var fields) = report(params, services: services) else { return .object(["typed": .bool(typed)]) }
        fields["typed"] = .bool(typed)
        return .object(fields)
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
