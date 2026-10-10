import AppKit
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSettingsWindow
import Observation

extension PageDescriptor {
    /// Debug Settings (cmux-page://cmux.debug-settings/, DEV and NIGHTLY builds): every tunable of
    /// the registry, drawn from data. The page writes the pasteboard for its two exports.
    static let debugSettings = PageDescriptor(
        id: "cmux.debug-settings", resource: "debug-settings", namespaces: ["cmux.debug.tunables."],
        nativeOps: [PageNativeOp.clipboardWrite], ownsSearchField: true)
}

/// The `cmux.debug.tunables.*` ops of the Debug Settings page, over the one ``DebugSettingsModel``
/// (the window, the tab and `debug.tunables` share it):
/// - `state`: ``DebugSettingsModel/pageState()`` (view state, sidebar, visible rows with controls);
/// - `view.set {query?, selection?}`: search and sidebar selection;
/// - `set {key, value}` (null resets) and `reset {key | section | all}`;
/// - `export {format: json | swift}`: the hand-off text (`{text}`); the page copies it;
/// - stream `changed`: `{state}` after any change of the store, the view state or the theme.
@MainActor
final class DebugSettingsPageProvider: PageProvider {
    private let model: DebugSettingsModel
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var watching = false

    init(model: DebugSettingsModel) {
        self.model = model
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let fields = params.objectValue ?? [:]
        switch op {
        case "cmux.debug.tunables.state":
            return model.pageState()
        case "cmux.debug.tunables.view.set":
            model.applyView(fields)
        case "cmux.debug.tunables.set":
            guard let key = fields["key"]?.stringValue, model.set(key: key, json: fields["value"]) else {
                throw PageError.invalidParams("unknown key or a value that does not fit it")
            }
        case "cmux.debug.tunables.reset":
            if fields["all"]?.boolValue == true {
                model.resetAll()
            } else if let id = fields["section"]?.stringValue, let section = model.sections.first(where: { $0.id == id }) {
                model.reset(section: section)
            } else if let key = fields["key"]?.stringValue, model.descriptors.contains(where: { $0.key == key }) {
                model.set(key: key, json: nil)
            } else {
                throw PageError.invalidParams("pass key, section or all")
            }
        case "cmux.debug.tunables.export":
            // nil pasteboard: the model sets its notice and returns the text; the page copies it.
            let text = fields["format"]?.stringValue == "swift" ? model.copySwift(to: nil) : model.copyJSON(to: nil)
            return ["text": .string(text)]
        default:
            throw PageError.unknownOp(op)
        }
        return model.pageState()
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == "cmux.debug.tunables.changed" else { throw PageError.unknownOp(stream) }
        let id = UUID()
        listeners[id] = onEvent
        if !watching { watch() }
        return PageSubscription { [weak self] in _ = self?.listeners.removeValue(forKey: id) }
    }

    /// Observation, re-armed after each change while a page listens; changes in one main-actor
    /// turn coalesce into one event.
    private func watch() {
        guard !listeners.isEmpty else {
            watching = false
            return
        }
        watching = true
        withObservationTracking { model.touchPageState() } onChange: { [weak self] in
            // task-owner: one coalesced change event; the provider re-arms its observation there
            Task { @MainActor in self?.changed() }
        }
    }

    private func changed() {
        let event: JSONValue = ["state": model.pageState()]
        for listener in listeners.values { listener(event) }
        watch()
    }
}
