import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import OSLog

/// The user's keybindings.json in the binding table (cx-9ce.17): the home
/// daemon owns the file (`keybindings-v1`, cmux-config); this reads it when
/// the daemon serves it and after every `keybindings-changed`, and loads its
/// entries and removals as the table's user layer (`KeyBindingLoader`, which
/// checks them against the catalog). The page's edits that cmux.json cannot
/// hold are written here; each returns once the table shows it.
@MainActor
final class KeybindingsFileService {
    private weak var services: AppServices?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "keybindings")
    private var listeners: [UUID: @MainActor () -> Void] = [:]
    /// The newest read: reads run one after another, so the last one wins.
    private var reading: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    /// Entries the catalog refused at the last load.
    private(set) var issues: [KeyBindingIssue] = []
    /// Each loaded entry as the file writes it (command, keys and `when`
    /// text): an edit names the entry so, since the daemon matches the text
    /// and the table holds canonical ids and `when` clauses.
    private var written: [KeyBinding: KeybindingsFileClient.Binding] = [:]

    init(services: AppServices) {
        self.services = services
    }

    /// The home daemon serves keybindings.json.
    var serves: Bool { services?.machines.local.supports(DaemonCapability.keybindings.rawValue) ?? false }

    func start() {
        services?.machines.local.store.sideEvents.subscribe { [weak self] event in
            if case .keybindingsChanged = event { self?.read() }
        }
        // task-owner: lives as long as the service; event-driven (Observation)
        observation = Task { [weak self] in
            // A trigger: a daemon restart that still serves keybindings reads them again.
            for await _ in ObservationStream({ [weak self] in ObservationTrigger(self?.serves ?? false) }) {
                guard let self else { return }
                await read().value
            }
        }
    }

    /// Calls `listener` after every load of the file and every edit of the
    /// binding table (``edited()``).
    func onChange(_ listener: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    /// An edit of the binding table, the page's or the socket's
    /// (``KeybindingPageWrites/run(_:_:services:)``): a cmux.json change
    /// loads no file, so the listeners (every open page) hear it here.
    func edited() {
        for listener in listeners.values { listener() }
    }

    // MARK: Writing

    /// Binds `command` on `key` (keybindings.json syntax) where `when` holds,
    /// with `args`; `replaces` (a table entry) goes, a default or app entry
    /// as a removal.
    func set(command: ActionID, key: String, when: String?, args: [String: JSONValue], replaces: KeyBinding?) async throws {
        let client = try client()
        let binding = KeybindingsFileClient.Binding(command: command.rawValue, key: key, when: when)
        try await client.set(binding, args: args, replaces: replaces.map(self.binding), idempotencyKey: Self.key())
        await read().value
    }

    /// Unbinds one table entry.
    func remove(_ entry: KeyBinding) async throws {
        try await client().remove(binding(entry), idempotencyKey: Self.key())
        await read().value
    }

    /// Drops the file's entries and removals of `command`.
    func reset(_ command: ActionID) async throws {
        try await client().reset(command: command.rawValue, idempotencyKey: Self.key())
        await read().value
    }

    // MARK: Reading

    /// Reads the file after any read in flight, and loads it.
    @discardableResult
    func read() -> Task<Void, Never> {
        let previous = reading
        // task-owner: one keybindings.get read; chained after the previous one
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard serves, let connection = services?.machines.local.connection else {
                load([])
                return
            }
            do {
                load(try await KeybindingsFileClient(connection: connection).get().entries)
            } catch {
                logger.error("keybindings.get: \(String(describing: error), privacy: .public)")
            }
        }
        reading = task
        return task
    }

    /// Loads `entries` as the table's user layer; the app layer stays.
    private func load(_ entries: [KeybindingsFileClient.Entry]) {
        var user: [KeyBinding] = [], removals: [KeyBindingRemoval] = []
        var texts: [KeybindingsFileClient.Binding] = []
        for entry in entries {
            let command = ActionID(rawValue: entry.command)
            if entry.removal {
                let keys = entry.keys.isEmpty ? nil : KeybindingReports.keys(from: entry.keys.joined(separator: " "))
                guard entry.keys.isEmpty || keys != nil, let when = Self.when(entry.when) else { continue }
                removals.append(KeyBindingRemoval(command: command, keys: keys, when: entry.when == nil ? .any : .exactly(when)))
            } else {
                guard let keys = KeybindingReports.keys(from: entry.keys.joined(separator: " ")), let when = Self.when(entry.when),
                      let arguments = Self.arguments(entry.args ?? [:]) else { continue }
                user.append(KeyBinding(keys: keys, command: command, arguments: arguments, when: when, source: .user))
                texts.append(KeybindingsFileClient.Binding(command: entry.command, key: entry.keys.joined(separator: " "), when: entry.when))
            }
        }
        guard let registry = services?.registry else { return }
        let layers = registry.keyBindingLayers
        issues = KeyBindingLoader(registry).load(KeyBindingLayers(app: layers.app, user: user, removals: removals))
        // The loader keeps the entries that pass, in order, canonicalized.
        let refused = Set(issues.filter { $0.source == .user && !$0.isRemoval }.map(\.index))
        let kept = texts.enumerated().filter { !refused.contains($0.offset) }.map(\.element)
        written = Dictionary(zip(registry.keyBindingLayers.user, kept), uniquingKeysWith: { first, _ in first })
        notify()
    }

    private func notify() {
        for listener in listeners.values { listener() }
    }

    private func client() throws -> KeybindingsFileClient {
        guard serves, let connection = services?.machines.local.connection else {
            throw KeybindingsFileError.notServed
        }
        return KeybindingsFileClient(connection: connection)
    }

    /// The table entry is one of keybindings.json's.
    func isFromFile(_ entry: KeyBinding) -> Bool {
        written[entry] != nil
    }

    /// The binding an edit names: a file entry as written, any other entry
    /// by its keys and canonical `when` text.
    private func binding(_ entry: KeyBinding) -> KeybindingsFileClient.Binding {
        written[entry] ?? KeybindingsFileClient.Binding(command: entry.command.rawValue, key: KeybindingReports.text(entry.keys),
                                                        when: entry.when?.text)
    }

    /// A parsed `when` (`.some(nil)`: none), or nil when it does not parse.
    private static func when(_ text: String?) -> WhenClause?? {
        guard let text else { return .some(nil) }
        do {
            return .some(try WhenClause.parse(text))
        } catch {
            return nil
        }
    }

    /// File arguments as action values (the loader converts them to the
    /// schema's kinds), or nil when one is a list, an object or null.
    private static func arguments(_ args: [String: JSONValue]) -> [String: ActionValue]? {
        var values: [String: ActionValue] = [:]
        for (name, value) in args {
            switch value {
            case .string(let text): values[name] = .string(text)
            case .bool(let flag): values[name] = .bool(flag)
            case .number(let number):
                guard let int = Int(exactly: number) else { values[name] = .string(String(number)); continue }
                values[name] = .int(int)
            default: return nil
            }
        }
        return values
    }

    private static func key() -> String { UUID().uuidString.lowercased() }
}

enum KeybindingsFileError: Error {
    /// The home daemon does not serve keybindings.json (yet, or any more).
    case notServed
}
