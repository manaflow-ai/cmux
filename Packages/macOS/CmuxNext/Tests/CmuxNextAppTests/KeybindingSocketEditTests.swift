import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextPages
@testable import CmuxNextSettings
import Foundation
import Testing

/// `keybinding.set` and `keybinding.remove` over the control socket (cx-9ce.26, R33: an agent
/// or a script changes a binding as the user does on the Keyboard Shortcuts page): the same
/// write as the page, so the key runs the action, cmux.json holds it, and an open page
/// re-lists. A key the recorder refuses is refused here too.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct KeybindingSocketEditTests {
    typealias Launch = KeybindingsFileRelaunchTests.Launch

    static let command = "about"
    static let key = "cmd+ctrl+opt+k"

    @Test func aBindingSetOverTheSocketRunsItsActionUntilItIsRemoved() async throws {
        try await Self.withLaunch("keysock") { launch, root in
            let router = Self.router(launch.services)
            let page = PageChanges()
            let subscription = try await launch.provider.subscribe("cmux.keybindings.changed", filter: .null,
                                                                   context: PageCallContext(page: "cmux.keybindings", userGesture: false)) { _ in page.count += 1 }
            defer { subscription.cancel() }
            // keybindings.json's first load may still be on its way: count from after it.
            await page.settle()
            #expect(try await Self.winner(Self.key, router) == nil, "\(Self.key) already runs something")

            let beforeSet = page.count
            let set = await router.handle(ControlRequest(id: "1", method: "keybinding.set", params: ["command": .string(Self.command), "key": .string(Self.key)]))
            #expect(throws: Never.self) { try set.get() }
            #expect(try await Self.winner(Self.key, router) == Self.command)
            let config = try String(contentsOf: root.appending(path: "cmux.json"), encoding: .utf8)
            #expect(config.contains("\"\(Self.command)\""), "cmux.json does not bind \(Self.command): \(config)")
            #expect(page.count > beforeSet, "an open Keyboard Shortcuts page did not hear the change")

            let beforeRemove = page.count
            let remove = await router.handle(ControlRequest(id: "2", method: "keybinding.remove", params: ["command": .string(Self.command), "key": .string(Self.key)]))
            #expect(throws: Never.self) { try remove.get() }
            #expect(try await Self.winner(Self.key, router) == nil, "\(Self.key) still runs \(Self.command)")
            #expect(page.count > beforeRemove, "an open Keyboard Shortcuts page did not hear the removal")
        }
    }

    @Test func aKeyTheRecorderRefusesIsRefusedOverTheSocket() async throws {
        try await Self.withLaunch("keysockno") { launch, _ in
            let router = Self.router(launch.services)
            // A bare letter is typing: the recorder needs Command or Control.
            let bare = await router.handle(ControlRequest(id: "1", method: "keybinding.set", params: ["command": .string(Self.command), "key": "k"]))
            #expect(Self.code(bare) == "unavailable", "\(bare)")
            let garbled = await router.handle(ControlRequest(id: "2", method: "keybinding.set", params: ["command": .string(Self.command), "key": "cmd+nokey"]))
            #expect(Self.code(garbled) == "invalid_params", "\(garbled)")
            let unknown = await router.handle(ControlRequest(id: "3", method: "keybinding.set", params: ["command": "no.such.action", "key": .string(Self.key)]))
            #expect(Self.code(unknown) == "invalid_params", "\(unknown)")
            let bareRuns = try await Self.winner("k", router)
            #expect(bareRuns == nil, "the refused bare key runs \(bareRuns ?? "")")
        }
    }

    /// The app on a fresh same-tree daemon with every action runnable; the daemon
    /// quits before its directory goes, whether `body` passed or threw.
    static func withLaunch(_ name: String, _ body: (Launch, URL) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = try NumberedShortcutPageTests.root(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let launch = try await Launch(root: root, session: "cn-\(name)-\(UUID().uuidString.prefix(8).lowercased())", binary: binary, noopActions: true)
        await launch.wait { launch.connected }
        let result: Result<Void, any Error>
        do {
            try #require(launch.connected, "the daemon does not serve keybindings")
            result = .success(try await body(launch, root))
        } catch { result = .failure(error) }
        await launch.quit()
        try result.get()
    }

    /// The app's control router with the keybinding methods, as the socket serves them.
    static func router(_ services: AppServices) -> ControlRouter {
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: services.registry), settings: nil,
                                   configuration: ControlRouter.Configuration(requestDeadline: .seconds(30)))
        router.register(KeybindingControl.methods(services: services))
        return router
    }

    /// The command `keys` runs (`keybinding.resolve`), or nil when none.
    static func winner(_ keys: String, _ router: ControlRouter) async throws -> String? {
        let report = try await router.handle(ControlRequest(id: "r", method: "keybinding.resolve", params: ["keys": .string(keys)])).get()
        guard case .object(let object) = report, object["outcome"]?.stringValue == "run", case .object(let winner)? = object["winner"] else { return nil }
        return winner["command"]?.stringValue
    }

    /// The `cmux.keybindings.changed` events an open page received.
    final class PageChanges {
        var count = 0

        /// Waits until no event came for half a second (5 s at most); test-only poll.
        func settle() async {
            let deadline = ContinuousClock.now + .seconds(5)
            var last = -1
            while count != last, ContinuousClock.now < deadline {
                last = count
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    static func code(_ result: Result<CmuxNextSettings.JSONValue, ControlError>) -> String? {
        if case .failure(let error) = result { return error.code }
        return nil
    }
}
