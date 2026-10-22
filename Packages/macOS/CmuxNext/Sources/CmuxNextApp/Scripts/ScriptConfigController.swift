import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import OSLog

/// The config scripts in the app (plans/cmux-next/scripting-runtime.md
/// section 10.3): the local daemon runs `scripts/*.js` beside the settings
/// file (`script-config-v1`); this loads them when the daemon serves them
/// and has none loaded, reads the report again after every
/// `script-config-changed`, and puts what they define in the registry:
/// each `user.<name>` action (the palette lists it unless a key function),
/// run through `script-action-run`; their key bindings and removals as the
/// table's app layer (`KeybindingsFileService.setScriptLayer`); their key
/// modes (``ScriptKeyModes``). Only the local daemon: a Cloud machine's
/// scripts are that machine's.
@MainActor
final class ScriptConfigController {
    private weak var services: AppServices?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "script-config")
    private var observation: Task<Void, Never>?
    /// The newest read: reads run one after another, so the last one wins.
    private var reading: Task<Void, Never>?
    private var registered: [ActionID] = []
    /// The last report applied, nil before the first.
    private(set) var report: ScriptConfigReport?
    let modes = ScriptKeyModes()

    /// An action past 60 s ends the config session (section 10.3); the reply waits a little longer.
    static let actionTimeout: Duration = .seconds(65)
    /// Every file has 10 s to run.
    static let reloadTimeout: Duration = .seconds(120)

    init(services: AppServices) {
        self.services = services
    }

    private var daemon: DaemonService? { services?.machines.local }
    var serves: Bool { daemon?.supports(DaemonCapabilities.shared.scriptConfig) ?? false }

    func start() {
        guard observation == nil, let services else { return }
        modes.registry = services.registry
        registerReload()
        daemon?.store.sideEvents.subscribe { [weak self] event in
            if case .scriptConfigChanged = event { self?.read(reloadIfEmpty: false) }
        }
        // task-owner: lives as long as the controller; event-driven (Observation)
        observation = Task { [weak self] in
            // A trigger: a daemon (re)start that serves config scripts loads them when it has none.
            for await _ in ObservationStream({ [weak self] in ObservationTrigger(self?.serves ?? false) }) {
                guard let self else { return }
                await read(reloadIfEmpty: true).value
            }
        }
    }

    // MARK: Reading

    /// Reads the report after any read in flight and applies it. With
    /// `reloadIfEmpty`, a daemon with no config loaded runs the scripts
    /// first (nothing runs before the app asks, section 10.3).
    @discardableResult
    func read(reloadIfEmpty: Bool) -> Task<Void, Never> {
        let previous = reading
        // task-owner: one script-config-status read; chained after the previous one
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard serves, let connection = daemon?.connection else {
                apply(nil)
                return
            }
            do {
                var report = try await connection.request(ScriptConfigStatusRequest())
                if reloadIfEmpty, !report.loaded {
                    report = try await connection.request(ScriptConfigReloadRequest(), timeout: Self.reloadTimeout)
                }
                apply(report)
            } catch {
                logger.error("script-config-status: \(String(describing: error), privacy: .public)")
            }
        }
        reading = task
        return task
    }

    /// Runs the config scripts again; the `script-config-changed` that an
    /// applied reload emits reads the report. A reload that kept the last
    /// good config says why.
    func reload() {
        guard let services, let connection = daemon?.connection, serves else {
            services?.registry.refuse(ScriptConfigStrings.notServed)
            return
        }
        // task-owner: one reload the person asked for; the refusal shows when it ends.
        Task { [weak self] in
            do {
                let report = try await connection.request(ScriptConfigReloadRequest(), timeout: Self.reloadTimeout)
                if let first = report.diagnostics.first { services.registry.refuse(ScriptConfigStrings.failed(Self.describe(first))) }
                if !report.applied { self?.apply(report) }
            } catch {
                services.registry.refuse(ScriptConfigStrings.failed(String(describing: error)))
            }
        }
    }

    // MARK: Applying

    /// Replaces the registry's `user.*` and `keyMode.*` actions, the script
    /// key layer and the key modes with `report`'s (none when nil).
    func apply(_ report: ScriptConfigReport?) {
        guard let services, report != self.report || report == nil else { return }
        self.report = report
        if let report, let first = report.diagnostics.first {
            logger.error("config scripts: \(Self.describe(first), privacy: .public)")
        }
        let registry = services.registry
        var ids: [ActionID] = []
        for action in report?.actions ?? [] {
            let id = ActionID(rawValue: action.id)
            var entry = Action(id: id, title: action.title, keywords: [action.name, action.description].compactMap { $0 },
                               invoke: { [weak self] in self?.run(action.id, invocation: $0) }, handler: {})
            if !action.palette { entry.paletteExemption = .scriptKeyFunction }
            registry.register(entry)
            ids.append(id)
        }
        ids += modes.load(report?.modes ?? [])
        for old in registered where !ids.contains(old) { registry.unbind(old) }
        registered = ids
        // The actions exist now: the loader checks the bindings against them.
        let (bindings, modeBindings) = Self.bindings(report?.keys ?? [], registry: registry)
        modes.bindings = modeBindings
        services.keybindingsFile.setScriptLayer(bindings: bindings, removals: Self.removals(report?.removals ?? []))
    }

    /// The table's bindings and each mode's, parsed. An entry whose keys or
    /// `when` do not parse is logged and left out; the loader reports the
    /// table's other refusals, ``ScriptKeyModes`` checks a mode's commands.
    private static func bindings(_ keys: [ScriptConfigReport.Key], registry: ActionRegistry)
        -> (table: [KeyBinding], modes: [String: [KeyBinding]]) {
        var table: [KeyBinding] = [], modes: [String: [KeyBinding]] = [:]
        let loader = KeyBindingLoader(registry)
        for key in keys {
            guard let strokes = KeybindingReports.keys(from: key.key), let when = KeybindingsFileService.when(key.when),
                  let arguments = KeybindingsFileService.arguments(key.args ?? [:]) else {
                Logger(subsystem: "com.cmuxterm.app.next", category: "script-config")
                    .error("config scripts: the binding \(key.key, privacy: .public) of \(key.command, privacy: .public) does not parse")
                continue
            }
            let binding = KeyBinding(keys: strokes, command: ActionID(rawValue: key.command), arguments: arguments, when: when, source: .app)
            guard let mode = key.mode else {
                table.append(binding)
                continue
            }
            if case .success(let checked) = loader.validatedCommand(binding) { modes[mode, default: []].append(checked) }
        }
        return (table, modes)
    }

    private static func removals(_ removals: [ScriptConfigReport.Removal]) -> [KeyBindingRemoval] {
        removals.compactMap { removal in
            guard let key = removal.key else { return KeyBindingRemoval(command: ActionID(rawValue: removal.command)) }
            guard let keys = KeybindingReports.keys(from: key) else { return nil }
            return KeyBindingRemoval(command: ActionID(rawValue: removal.command), keys: keys)
        }
    }

    static func describe(_ diagnostic: ScriptConfigReport.Diagnostic) -> String {
        var place = diagnostic.file.map { ($0 as NSString).lastPathComponent } ?? ""
        if let line = diagnostic.line { place += ":\(line)" + (diagnostic.column.map { ":\($0)" } ?? "") }
        return place.isEmpty ? diagnostic.message : "\(place): \(diagnostic.message)"
    }

    // MARK: Running

    /// Runs config action `id` in the daemon's config session; a refusal
    /// shows the script's error.
    private func run(_ id: String, invocation: ActionInvocation) {
        guard let services, let connection = daemon?.connection else { return }
        let request = ScriptActionRunRequest(action: id, args: Self.arguments(invocation.arguments), context: context(invocation))
        // task-owner: one script action run; the refusal shows when it ends.
        Task {
            do {
                _ = try await connection.request(request, timeout: Self.actionTimeout)
            } catch DaemonError.command(_, let message, _, _, _) {
                services.registry.refuse(ScriptConfigStrings.failed(message))
            } catch {
                services.registry.refuse(ScriptConfigStrings.failed(String(describing: error)))
            }
        }
    }

    /// What the action's `ctx` says: who ran it and the focused objects' public ids.
    private func context(_ invocation: ActionInvocation) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["origin": .string(Self.origin(invocation))]
        guard let services, let pane = services.windows.active?.focusedPane else { return fields }
        if let id = pane.pane.resourceID { fields["pane"] = .string(id.rawValue) }
        if let workspace = services.daemon.store.workspace(containing: pane.pane.handle)?.resourceID {
            fields["workspace"] = .string(workspace.rawValue)
        }
        if let selected = pane.stripModel.selectedID, let tab = pane.tab(selected) {
            if let id = tab.resourceID { fields["tab"] = .string(id.rawValue) }
            if let id = tab.terminalResourceID { fields["terminal"] = .string(id.rawValue) }
        }
        return fields
    }

    /// `key` for a key-down, `palette` for the person's other gestures, else the caller's origin.
    nonisolated static func origin(_ invocation: ActionInvocation) -> String {
        if invocation.keyContext != nil { return "key" }
        return invocation.origin == .user ? "palette" : invocation.origin.rawValue
    }

    nonisolated static func arguments(_ arguments: [String: ActionValue]) -> [String: JSONValue] {
        arguments.mapValues { value in
            switch value {
            case .string(let text): .string(text)
            case .int(let number): .number(Double(number))
            case .bool(let flag): .bool(flag)
            case .target(let ref): .string(ref.description)
            }
        }
    }

    private func registerReload() {
        services?.registry.register(Action(id: Self.reloadID, title: ScriptConfigStrings.reload,
                                           keywords: ["scripts", "config", "init.js", "reload"],
                                           handler: { [weak self] in self?.reload() }))
    }

    static let reloadID: ActionID = "scriptConfig.reload"
}
