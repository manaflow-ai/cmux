import AppKit
import CmuxNextControl
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
/// - `hangs.reveal {path?}` and `hangs.copy {path}`: a recent hang file (``HangFileTunables``);
/// - stream `changed`: `{state}` after any change of the store, the view state, the theme or the
///   hang files.
@MainActor
final class DebugSettingsPageProvider: PageProvider {
    private let model: DebugSettingsModel
    /// The watchdog's hang files, listed in the state's `hangs`.
    private let hangs: HangEpisodeRecorder?
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var watching = false
    /// Follows ``HangEpisodeRecorder/changes()`` while a page listens.
    private var hangWatch: Task<Void, Never>?

    init(model: DebugSettingsModel, hangs: HangEpisodeRecorder?) {
        self.model = model
        self.hangs = hangs
    }

    /// Defense only: ends the hang watch of a provider released while a caller still listens
    /// with an `onEvent` that does not hold it. A page's router holds the provider through its
    /// `onEvent` (kept in ``listeners``), so a page's watch ends at unsubscribe, which closing the
    /// page's tab or window runs (``DebugSettingsService``), never here.
    nonisolated deinit { hangWatch?.cancel() }

    /// The model's page state with the recent hangs.
    private func state() -> JSONValue {
        guard case .object(var fields) = model.pageState() else { return model.pageState() }
        fields["hangs"] = HangFileTunables.pageJSON(hangs)
        return .object(fields)
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let fields = params.objectValue ?? [:]
        switch op {
        case "cmux.debug.tunables.state":
            return state()
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
        case "cmux.debug.tunables.hangs.reveal":
            try HangFileTunables.reveal(hangs, path: fields["path"]?.stringValue)
        case "cmux.debug.tunables.hangs.copy":
            return try await HangFileTunables.text(hangs, path: fields["path"]?.stringValue)
        default:
            throw PageError.unknownOp(op)
        }
        return state()
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == "cmux.debug.tunables.changed" else { throw PageError.unknownOp(stream) }
        let id = UUID()
        listeners[id] = onEvent
        if !watching { watch() }
        if hangWatch == nil, let changes = hangs?.changes() { // subscribed now: no later change is missed
            // task-owner: one change event per hang file change; the last listener leaving (the page closed) cancels it
            hangWatch = Task { @MainActor [weak self] in
                for await _ in changes { if let self { emit() } else { return } } // gone: the stream ends
            }
        }
        return PageSubscription { [weak self] in self?.unsubscribe(id) }
    }

    /// The last listener leaving stops following the hang files (the Observation watch ends at
    /// its next change, ``watch()``).
    private func unsubscribe(_ id: UUID) {
        listeners.removeValue(forKey: id)
        guard listeners.isEmpty, let hangWatch else { return }
        hangWatch.cancel()
        self.hangWatch = nil
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
        emit()
        watch()
    }

    private func emit() {
        guard !listeners.isEmpty else { return }
        let event: JSONValue = ["state": state()]
        for listener in listeners.values { listener(event) }
    }
}
