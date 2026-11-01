import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSettings
import Foundation
import Testing

/// The shared conformance vectors (`schemas/keybindings/keybinding-vectors.json`,
/// R59) run through keybindings.json: each vector's entries and removals
/// are written to the file the daemon watches, and once the app loaded
/// them its binding table resolves the vector's keys as the file says. A
/// vector that expects a refusal (a bare first key outside a bare-key page,
/// K1) loads none of its entries: the daemon leaves them out of the file's
/// entries and the app's loader refuses them too.
///
/// A rebind the Keyboard Shortcuts page makes that cmux.json cannot hold
/// (three keys) goes to keybindings.json through the real daemon
/// (cx-9ce.17), and the binding table has it again after cmux and the
/// daemon relaunch.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct KeybindingsFileRelaunchTests {
    /// One launch of cmux and its daemon on `root`'s state and config.
    struct Launch {
        let services: AppServices
        let provider: KeybindingsPageProvider

        /// `noopActions`: every catalog action runs anywhere its context holds
        /// (the vectors' rule) instead of the app's handlers.
        init(root: URL, session: String, binary: URL, noopActions: Bool = false) async throws {
            let config = root.appending(path: "cmux.json")
            let launcher = DaemonLauncher(
                configuration: .init(binary: binary, session: session, stateDirectory: root.appending(path: "state")),
                environment: {
                    ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color",
                     "CMUX_NEXT_CONFIG_FILE": config.path]
                })
            _ = NSApplication.shared
            let services = AppServices(environment: AppEnvironment.current([:]))
            if noopActions {
                for descriptor in services.registry.descriptors { services.registry.bind(descriptor.id, invoke: { _ in }) }
            } else {
                AppActions.bind(services)
            }
            let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: config,
                                              managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
            await settings.reload()
            services.settings = settings
            services.daemon.start {
                DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
            }
            services.keybindingsFile.start()
            self.services = services
            provider = KeybindingsPageProvider(services: services)
        }

        /// Waits (up to `limit`) until `condition` holds; test-only poll.
        func wait(within limit: Duration = .seconds(60), _ condition: () -> Bool) async {
            let deadline = ContinuousClock.now + limit
            while !condition(), ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        var connected: Bool {
            services.machines.local.connection != nil && services.machines.local.supports(DaemonCapability.keybindings.rawValue)
        }

        func entries(_ command: ActionID, keys: [Shortcut]) -> [KeyBinding] {
            RegistryKeyBindings(services.registry).table.entries.filter { $0.command == command && $0.keys == keys }
        }

        func call(_ op: String, _ params: CmuxNextSettings.JSONValue) async throws -> CmuxNextSettings.JSONValue {
            try await provider.call(op, params: params, context: PageCallContext(page: "cmux.keybindings", userGesture: true))
        }

        /// Ends the daemon and the connection.
        func quit() async {
            if let connection = services.daemon.connection, let identity = services.daemon.identity {
                _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                                  timeout: .seconds(10))
            }
            services.daemon.shutdownConnection()
        }
    }

    @Test func aThreeKeyRebindFromThePageIsInTheTableAfterARelaunch() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appending(path: "cn-keys-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appending(path: "cmux.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "cn-keys-\(UUID().uuidString.prefix(8).lowercased())"
        let command = ActionID(rawValue: "nextSurface")
        let text = "cmd+ctrl+opt+u x y"  // no default key starts it (Ctrl-Opt-Cmd-J is New Row)
        let keys = try #require(KeybindingReports.keys(from: text))

        let first = try await Launch(root: root, session: session, binary: binary)
        await first.wait { first.connected }
        var failure: String?
        do {
            _ = try await first.call("cmux.keybindings.set", ["command": .string(command.rawValue), "key": .string(text)])
        } catch {
            failure = String(describing: error)
        }
        let written = first.entries(command, keys: keys).map(\.source)
        await first.quit()
        #expect(failure == nil, "the page refused the rebind")
        #expect(written == [.user], "the table did not show the rebind once set returned")
        let file = (try? String(contentsOf: root.appending(path: "keybindings.json"), encoding: .utf8)) ?? ""
        // The daemon writes normalized strokes (cmd, shift, opt, ctrl), as the page lists them.
        #expect(file.contains("nextSurface") && file.contains(KeybindingReports.text(keys)), "keybindings.json: \(file)")

        let second = try await Launch(root: root, session: session, binary: binary)
        await second.wait { second.connected && !second.entries(command, keys: keys).isEmpty }
        let relaunched = second.entries(command, keys: keys).map(\.source)
        await second.quit()
        #expect(relaunched == [.user], "the rebind was gone after the relaunch")
    }

    enum Outcome: Equatable {
        case action(String, CmuxNextSettings.JSONValue?)
        case armed
        case none
    }

    @Test func theConformanceVectorsResolveFromKeybindingsJSON() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        var schemas = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { schemas.deleteLastPathComponent() }
        let vectors = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: schemas.appending(path: "schemas/keybindings/keybinding-vectors.json"))) as? [String: Any])
        let rows = try #require(vectors["vectors"] as? [[String: Any]])
        #expect(rows.count >= 20)
        let root = FileManager.default.temporaryDirectory.appending(path: "cn-keyvec-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appending(path: "cmux.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "keybindings.json")
        let launch = try await Launch(root: root, session: "cn-keyvec-\(UUID().uuidString.prefix(8).lowercased())", binary: binary,
                                      noopActions: true)
        await launch.wait { launch.connected }
        var results: [String] = []
        for (index, row) in rows.enumerated() {
            let name = row["name"] as? String ?? "?"
            let bindings = row["bindings"] as? [[String: Any]] ?? []
            let expect = row["expect"] as? [String: Any] ?? [:]
            let refused = expect["refused"] as? Bool == true
            let loaded = refused ? 0 : bindings.count
            let removals = (row["removals"] as? [[String: Any]] ?? []).map { entry in
                entry.merging(["command": "-" + (entry["command"] as? String ?? "")]) { $1 }
            }
            // A marker entry makes every vector's file differ from the last one's.
            let mark = "vectorIndex == v\(index)"
            let marker: [String: Any] = ["key": "cmd+ctrl+opt+shift+0", "command": "toggleSidebar", "when": mark]
            try JSONSerialization.data(withJSONObject: bindings + removals + [marker]).write(to: file, options: .atomic)
            // The marker shows the file loaded; a file normally loads in well under a second.
            await launch.wait(within: .seconds(10)) {
                let layers = launch.services.registry.keyBindingLayers
                return layers.user.last?.when?.text == (try? WhenClause.parse(mark))?.text && layers.removals.count == removals.count
            }
            let user = launch.services.registry.keyBindingLayers.user.count - 1
            if user != loaded { results.append("\(name): the table has \(user) of the vector's entries, expected \(loaded)") }
            // The app's loader refuses nothing the daemon passed: both apply the same rules.
            let issues = launch.services.keybindingsFile.issues
            if !issues.isEmpty { results.append("\(name): the app's loader refused \(issues)") }
            if refused {
                // The app's own check refuses the entries too (a cmux.json or app entry has no daemon in front).
                for entry in bindings {
                    guard let keys = KeybindingReports.keys(from: entry["key"] as? String ?? "") else { continue }
                    let when = (entry["when"] as? String).flatMap { try? WhenClause.parse($0) }
                    let binding = KeyBinding(keys: keys, command: ActionID(rawValue: entry["command"] as? String ?? ""), when: when, source: .user)
                    if case .success = KeyBindingLoader(launch.services.registry).validated(binding) {
                        results.append("\(name): the app's loader accepts \(entry)")
                    }
                }
            }
            let context = (row["context"] as? [String: Any] ?? [:]).compactMapValues { any -> KeyContextValue? in
                if let flag = any as? Bool, CFGetTypeID(any as CFTypeRef) == CFBooleanGetTypeID() { return .bool(flag) }
                if let number = any as? Double { return .number(number) }
                return (any as? String).map(KeyContextValue.string)
            }
            let keys = (row["keys"] as? [String] ?? []).joined(separator: " ")
            let report = KeybindingReports.resolve(keys, context: KeyContext(context), registry: launch.services.registry, window: nil)
            guard case .object(let object)? = report else {
                results.append("\(name): keys do not parse")
                continue
            }
            let winner = object["winner"]?.objectValue
            let actual: Outcome = switch object["outcome"]?.stringValue {
            case "run": .action(winner?["command"]?.stringValue ?? "?", winner?["args"])
            case "armed": .armed
            default: .none
            }
            let expected: Outcome
            if let action = expect["action"] as? String {
                let args = (expect["args"] as? [String: Any]).map { args in
                    CmuxNextSettings.JSONValue.object(args.mapValues { any in
                        if let flag = any as? Bool, CFGetTypeID(any as CFTypeRef) == CFBooleanGetTypeID() { return .bool(flag) }
                        if let number = any as? Int { return CmuxNextSettings.JSONValue(number) }
                        return .string("\(any)")
                    })
                }
                expected = .action(action, args)
            } else {
                expected = expect["armed"] as? Bool == true ? .armed : .none
            }
            if actual != expected { results.append("\(name): \(actual), expected \(expected)") }
        }
        await launch.quit()
        #expect(results.isEmpty, "\(results.joined(separator: "\n"))")
    }

    /// A hand-written entry whose `when` is not in canonical form, removed
    /// from the page (which lists the canonical text), goes from the file:
    /// the edit names the entry as the file writes it.
    @Test func removingAHandWrittenEntryFromThePageTakesItOutOfTheFile() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appending(path: "cn-keyrm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appending(path: "cmux.json"))
        let file = root.appending(path: "keybindings.json")
        try Data(#"[{"key": "cmd+ctrl+opt+k x", "command": "nextSurface", "when": "surfaceKind==terminal"}]"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        let command = ActionID(rawValue: "nextSurface")
        let keys = try #require(KeybindingReports.keys(from: "cmd+ctrl+opt+k x"))

        let launch = try await Launch(root: root, session: "cn-keyrm-\(UUID().uuidString.prefix(8).lowercased())", binary: binary)
        await launch.wait { launch.connected && !launch.entries(command, keys: keys).isEmpty }
        let listed = launch.entries(command, keys: keys).first?.when?.text
        var failure: String?
        do {
            _ = try await launch.call("cmux.keybindings.remove", [
                "command": .string(command.rawValue), "key": .string(KeybindingReports.text(keys)),
                "when": listed.map(CmuxNextSettings.JSONValue.string) ?? .null,
            ])
        } catch {
            failure = String(describing: error)
        }
        let left = launch.entries(command, keys: keys).count
        await launch.quit()
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        #expect(listed == "surfaceKind == terminal")
        #expect(failure == nil, "the page refused the remove: \(failure ?? "")")
        #expect(left == 0, "the binding is still in the table")
        #expect(!text.contains("nextSurface"), "keybindings.json kept the entry or gained a removal: \(text)")
    }
}
