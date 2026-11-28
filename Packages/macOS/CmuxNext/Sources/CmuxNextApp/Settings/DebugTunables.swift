#if DEBUG
import AppKit
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSettingsWindow

// `debug.tunables` (DEBUG builds): drives Debug Settings and the tunable
// store the way the window's controls do, so automation can open the
// window, search, change values and export without synthesizing input.
// Params: `action`:
// - `state` (default): availability, the override file, change count, and
//   the window (open, visible, key, CGWindowID, query, selection, rows);
// - `list` (`query`, `section`, `changed`): tunables with value and default;
// - `get` / `set` (`key`, `value` JSON; null resets) / `reset` (`key`,
//   `section`, or `all: true`);
// - `export` (`format`: json | swift): the hand-off text;
// - `open` (`query`, `section`), `query` (`text`), `section` (`id`, or
//   `all` / `changed`), `close`: the window.
enum DebugTunables {
    static func handle(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let service = services.debugSettings
        let store = TunableStore.shared
        switch params["action"]?.stringValue ?? "state" {
        case "list":
            var rows = TunableCatalog.all
            if let query = params["query"]?.stringValue { rows = TunableSearch.filter(rows, query: query) }
            if let section = params["section"]?.stringValue { rows = rows.filter { $0.section.id == section } }
            if params["changed"]?.boolValue == true { rows = rows.filter { isChanged($0, store) } }
            return .object(["count": JSONValue(rows.count), "tunables": .array(rows.map { row($0, store) })])
        case "get":
            guard let descriptor = descriptor(params) else { return error("unknown key") }
            return row(descriptor, store)
        case "set":
            guard let descriptor = descriptor(params) else { return error("unknown key") }
            guard let raw = params["value"], raw != .null else {
                store.reset([descriptor.key])
                return row(descriptor, store)
            }
            guard let value = tunableValue(raw, kind: descriptor.kind) else { return error("value does not fit \(descriptor.key)") }
            if descriptor.clamp(value) == descriptor.defaultValue { store.reset([descriptor.key]) } else { store.set(descriptor.key, value) }
            return row(descriptor, store)
        case "reset":
            if params["all"]?.boolValue == true {
                store.resetAll()
            } else if let section = params["section"]?.stringValue {
                store.reset(TunableCatalog.all.filter { $0.section.id == section }.map(\.key))
            } else if let descriptor = descriptor(params) {
                store.reset([descriptor.key])
            } else {
                return error("pass key, section or all")
            }
        case "export":
            let changes = TunableExport.changes(descriptors: TunableCatalog.all, overrides: store.overrides)
            let text = params["format"]?.stringValue == "swift" ? TunableExport.swiftDefaults(changes) : TunableExport.json(changes)
            return .object(["count": JSONValue(changes.count), "text": .string(text)])
        case "open":
            do {
                try service.show(query: params["query"]?.stringValue, selection: params["section"]?.stringValue.map(selection))
            } catch {
                return self.error(String(describing: error))
            }
        case "query":
            guard let model = service.model else { return error("Debug Settings is not open") }
            model.query = params["text"]?.stringValue ?? ""
        case "section":
            guard let model = service.model else { return error("Debug Settings is not open") }
            model.query = ""
            model.selection = selection(params["id"]?.stringValue ?? "all")
        case "close":
            service.close()
        case "state":
            break
        default:
            return error("unknown action")
        }
        return state(services)
    }

    static func state(_ services: AppServices) -> JSONValue {
        let service = services.debugSettings
        let store = TunableStore.shared
        var fields: [String: JSONValue] = [
            "available": .bool(service.isAvailable),
            "active": .bool(store.isActive),
            "file": service.fileURL.map { .string($0.path) } ?? .null,
            "tunables": JSONValue(TunableCatalog.all.count),
            "changed": JSONValue(TunableCatalog.all.count { isChanged($0, store) }),
        ]
        if let model = service.model, let window = service.window {
            let selection: String = switch model.selection {
            case .all: "all"
            case .changed: "changed"
            case .section(let id): id
            }
            fields["window"] = .object([
                "visible": .bool(window.isVisible),
                "key": .bool(window.isKeyWindow),
                "window_number": JSONValue(window.windowNumber),
                "frame": .array([window.frame.minX, window.frame.minY, window.frame.width, window.frame.height].map { .number(Double($0)) }),
                "query": .string(model.query),
                "selection": .string(selection),
                "rows": JSONValue(model.visible.count),
                "first_rows": .array(model.visible.prefix(12).map { .string($0.key) }),
                "notice": model.notice.map(JSONValue.string) ?? .null,
            ])
        } else {
            fields["window"] = .null
        }
        return .object(fields)
    }

    private static func selection(_ id: String) -> DebugSettingsSelection {
        switch id {
        case "all": .all
        case "changed": .changed
        default: .section(id)
        }
    }

    private static func descriptor(_ params: [String: JSONValue]) -> TunableDescriptor? {
        guard let key = params["key"]?.stringValue else { return nil }
        return TunableCatalog.all.first { $0.key == key }
    }

    private static func isChanged(_ descriptor: TunableDescriptor, _ store: TunableStore) -> Bool {
        guard let value = store.override(descriptor.key) else { return false }
        return value != descriptor.defaultValue
    }

    private static func row(_ descriptor: TunableDescriptor, _ store: TunableStore) -> JSONValue {
        let value = store.override(descriptor.key) ?? descriptor.defaultValue
        return .object([
            "key": .string(descriptor.key), "section": .string(descriptor.section.id), "label": .string(descriptor.label),
            "value": json(value), "default": json(descriptor.defaultValue), "changed": .bool(isChanged(descriptor, store)),
        ])
    }

    private static func json(_ value: TunableValue) -> JSONValue {
        switch value {
        case .number(let number): .number(number)
        case .bool(let flag): .bool(flag)
        case .choice(let raw): .string(raw)
        case .color(let color): .string(color.rawValue)
        case .spring(let spring): .object(["response": .number(spring.response), "dampingFraction": .number(spring.dampingFraction)])
        }
    }

    private static func tunableValue(_ json: JSONValue, kind: TunableKind) -> TunableValue? {
        switch kind {
        case .number: json.doubleValue.map(TunableValue.number)
        case .bool: json.boolValue.map(TunableValue.bool)
        case .choice: json.stringValue.map(TunableValue.choice)
        case .color: json.stringValue.flatMap(TunableColor.init(rawValue:)).map(TunableValue.color)
        case .spring:
            json["response"]?.doubleValue.flatMap { response in
                json["dampingFraction"]?.doubleValue.map { .spring(SpringParameters(response: response, dampingFraction: $0)) }
            }
        }
    }

    private static func error(_ message: String) -> JSONValue { .object(["error": .string(message)]) }
}
#endif
