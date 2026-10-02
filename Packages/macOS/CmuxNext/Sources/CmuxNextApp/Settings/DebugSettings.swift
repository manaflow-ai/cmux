import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings
import CmuxNextSettingsWindow

// `debug.settings` (DEBUG builds): drives the open Settings window's model
// the way its controls do, so automation verifies the window without
// synthesizing system input (no-activate launches never take the keyboard).
// Params: `action`:
// - `state` (default): section, query, recorder, notice, write error, the
//   window's CGWindowID and whether it is visible or key;
// - `section` (`section`): select a section;
// - `set` (`key`, `value` JSON; `value` null resets): what a control does;
// - `record` (`id`): click an action's shortcut (starts the recorder);
// - `choose` (`option`: save, replace, keepBoth, cancel, remove, restoreDefault);
// - `query` (`text`): the search field.
// Keys for the recorder go through `debug.key` with `"target": "settings"`.
extension AppControl {
    func registerSettingsDebugMethods(_ services: AppServices) {
        #if DEBUG
        service?.router.register([
            .mainActor("debug.settings") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugSettings.handle(call.params, services: services))
            },
            // Debug Settings window and tunable store (DebugTunables).
            .mainActor("debug.tunables") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugTunables.handle(call.params, services: services))
            },
        ])
        #endif
    }
}

#if DEBUG
enum DebugSettings {
    static func handle(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let model = services.settingsWindow.model else { return .object(["error": .string("the Settings window is not open")]) }
        switch params["action"]?.stringValue ?? "state" {
        case "section":
            guard let section = params["section"]?.stringValue.flatMap(SettingsSection.init(rawValue:)) else {
                return .object(["error": .string("unknown section")])
            }
            model.query = ""
            model.selection = section
        case "set":
            guard let key = params["key"]?.stringValue,
                  let descriptor = SettingsSchema.descriptor(for: CmuxConfigFile.keyPath(from: key)) else {
                return .object(["error": .string("no schema setting with this key")])
            }
            let value = params["value"].flatMap { $0 == .null ? nil : $0 }
            if let value, !descriptor.accepts(value) { return .object(["error": .string("refused by the schema")]) }
            model.set(descriptor, value)
        case "record":
            guard let id = params["id"]?.stringValue, model.beginRecording(ActionID(rawValue: id)) else {
                return .object(["error": .string("cannot record this action")])
            }
        case "choose":
            let options: [String: ShortcutRecorderOption] = [
                "save": .save, "replace": .replace, "keepBoth": .keepBoth, "cancel": .cancel, "remove": .remove, "restoreDefault": .restoreDefault,
            ]
            guard let option = params["option"]?.stringValue.flatMap({ options[$0] }) else { return .object(["error": .string("unknown option")]) }
            model.chooseRecorderOption(option)
        case "query":
            model.query = params["text"]?.stringValue ?? ""
        case "state":
            break
        default:
            return .object(["error": .string("unknown action")])
        }
        return state(model, window: services.settingsWindow.window)
    }

    static func state(_ model: SettingsWindowModel, window: NSWindow?) -> JSONValue {
        .object([
            "section": .string(model.selection.rawValue),
            "query": .string(model.query),
            "window_number": window.map { .number(Double($0.windowNumber)) } ?? .null,
            "visible": .bool(window?.isVisible ?? false),
            "key": .bool(window?.isKeyWindow ?? false),
            "write_error": model.writeError.map(JSONValue.string) ?? .null,
            "notice": model.notice.map { .object(["action": .string($0.actionID.rawValue), "text": .string($0.text)]) } ?? .null,
            "recorder": model.recorder.map { recorder in
                .object(["action": .string(recorder.actionID.rawValue), "message": recorder.message.map(JSONValue.string) ?? .null,
                         "recorded": recorder.recorded.map { .string($0.displayString) } ?? .null,
                         "owners": .array((recorder.pending?.owners ?? []).map { .string($0.rawValue) }),
                         "options": .array(recorder.options.map { .string("\($0)") })])
            } ?? .null,
        ])
    }
}
#endif
