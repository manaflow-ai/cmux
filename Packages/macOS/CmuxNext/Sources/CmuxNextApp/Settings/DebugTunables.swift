#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSettingsWindow

// `debug.tunables` (DEBUG and bench builds) drives Debug Settings and the tunable store as the window's controls do,
// so automation can open the window, search, change values and export without synthesizing input. Params `action`:
// - `state` (default): availability, `active` (the store is on), the override file, change count, and the window
//   (open, visible, key, CGWindowID, query, selection, rows);
// - `activate`: turns on a store that launch left off (bench builds), for this launch, in memory only (debug-settings.md);
// - `list` (`query`, `section`, `changed`): tunables with value and default;
// - `get` / `set` (`key`, `value` JSON; null resets) / `reset` (`key`, `section`, or `all: true`); every row carries
//   `read_cadence` and `applies`, which is false for a key this process read at launch (relaunch to use the new value);
// - `export` (`format`: json | swift): the hand-off text;
// - `open` (`query`, `section`), `query` (`text`), `section` (`id`, or `all` / `changed`), `close`: the window.
enum DebugTunables {
    static func handle(_ params: [String: JSONValue], services: AppServices, store: TunableStore = .shared,
                       catalog: [TunableDescriptor] = TunableCatalog.all) -> JSONValue {
        let service = services.debugSettings
        switch params["action"]?.stringValue ?? "state" {
        case "list":
            var rows = catalog
            if let query = params["query"]?.stringValue { rows = TunableSearch.filter(rows, query: query) }
            if let section = params["section"]?.stringValue { rows = rows.filter { $0.section.id == section } }
            if params["changed"]?.boolValue == true { rows = rows.filter { isChanged($0, store) } }
            return .object(["count": JSONValue(rows.count), "tunables": .array(rows.map { row($0, store) })])
        case "get":
            guard let descriptor = descriptor(params, catalog) else { return error("unknown key") }
            return row(descriptor, store)
        case "set":
            guard let descriptor = descriptor(params, catalog) else { return error("unknown key") }
            guard let raw = params["value"], raw != .null else {
                store.reset([descriptor.key])
                return row(descriptor, store)
            }
            guard let value = DebugSettingsModel.tunableValue(raw, kind: descriptor.kind) else { return error("value does not fit \(descriptor.key)") }
            if descriptor.clamp(value) == descriptor.defaultValue { store.reset([descriptor.key]) } else { store.set(descriptor.key, value) }
            return row(descriptor, store)
        case "reset":
            if params["all"]?.boolValue == true {
                store.resetAll()
            } else if let section = params["section"]?.stringValue {
                store.reset(catalog.filter { $0.section.id == section }.map(\.key))
            } else if let descriptor = descriptor(params, catalog) {
                store.reset([descriptor.key])
            } else {
                return error("pass key, section or all")
            }
        case "export":
            let changes = TunableExport.changes(descriptors: catalog, overrides: store.overrides)
            let text = params["format"]?.stringValue == "swift" ? TunableExport.swiftDefaults(changes) : TunableExport.json(changes)
            return .object(["count": JSONValue(changes.count), "text": .string(text)])
        case "open":
            do {
                try service.show(query: params["query"]?.stringValue, selection: params["section"]?.stringValue.map(DebugSettingsSelection.init(id:)))
            } catch {
                return self.error(String(describing: error))
            }
        case "query":
            guard let model = service.model else { return error("Debug Settings is not open") }
            model.query = params["text"]?.stringValue ?? ""
        case "section":
            guard let model = service.model else { return error("Debug Settings is not open") }
            model.query = ""
            model.selection = DebugSettingsSelection(id: params["id"]?.stringValue ?? "all")
        case "close":
            service.close()
        case "activate" where !store.isActive:
            store.register(catalog)
            store.activate(file: nil)
        case "activate", "state":
            break
        default:
            return error("unknown action")
        }
        return state(services, store: store, catalog: catalog)
    }

    static func state(_ services: AppServices, store: TunableStore = .shared,
                      catalog: [TunableDescriptor] = TunableCatalog.all) -> JSONValue {
        let service = services.debugSettings
        var fields: [String: JSONValue] = [
            "available": .bool(service.isAvailable),
            "active": .bool(store.isActive),
            "file": service.fileURL.map { .string($0.path) } ?? .null,
            "tunables": JSONValue(catalog.count),
            "changed": JSONValue(catalog.count { isChanged($0, store) }),
        ]
        if let model = service.model, let window = service.window {
            fields["window"] = .object([
                "visible": .bool(window.isVisible),
                "key": .bool(window.isKeyWindow),
                "window_number": JSONValue(window.windowNumber),
                "frame": .array([window.frame.minX, window.frame.minY, window.frame.width, window.frame.height].map { .number(Double($0)) }),
                "query": .string(model.query),
                "selection": .string(model.selection.id),
                "rows": JSONValue(model.visible.count),
                "first_rows": .array(model.visible.prefix(12).map { .string($0.key) }),
                "notice": model.notice.map(JSONValue.string) ?? .null,
            ])
        } else {
            fields["window"] = .null
        }
        return .object(fields)
    }

    private static func descriptor(_ params: [String: JSONValue], _ catalog: [TunableDescriptor]) -> TunableDescriptor? {
        guard let key = params["key"]?.stringValue else { return nil }
        return catalog.first { $0.key == key }
    }

    private static func isChanged(_ descriptor: TunableDescriptor, _ store: TunableStore) -> Bool {
        DebugSettingsModel.isChanged(descriptor, store)
    }

    private static func row(_ descriptor: TunableDescriptor, _ store: TunableStore) -> JSONValue {
        DebugSettingsModel.tunableRow(descriptor, store)
    }

    private static func error(_ message: String) -> JSONValue { .object(["error": .string(message)]) }
}
#endif
