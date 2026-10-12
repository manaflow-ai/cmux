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

        init(root: URL, session: String, binary: URL) async throws {
            let config = root.appending(path: "cmux.json")
            let launcher = DaemonLauncher(
                configuration: .init(binary: binary, session: session, stateDirectory: root.appending(path: "state")),
                environment: {
                    ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color",
                     "CMUX_NEXT_CONFIG_FILE": config.path]
                })
            _ = NSApplication.shared
            let services = AppServices(environment: AppEnvironment.current([:]))
            AppActions.bind(services)
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

        /// Waits (up to 60 s) until `condition` holds; test-only poll.
        func wait(_ condition: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(60)
            while !condition(), ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        var connected: Bool {
            services.machines.local.connection != nil && services.machines.local.supports(DaemonCapabilities.shared.keybindings)
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
        let text = "cmd+ctrl+opt+j x y"
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
        #expect(file.contains("nextSurface") && file.contains("cmd+ctrl+opt+j x y"), "keybindings.json: \(file)")

        let second = try await Launch(root: root, session: session, binary: binary)
        await second.wait { second.connected && !second.entries(command, keys: keys).isEmpty }
        let relaunched = second.entries(command, keys: keys).map(\.source)
        await second.quit()
        #expect(relaunched == [.user], "the rebind was gone after the relaunch")
    }
}
