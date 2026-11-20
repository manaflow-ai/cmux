import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// OWNERSHIP-PRINCIPLES.md: every action.run carries its origin; only a
/// user's run (or one asking `focus: true`) may change this client's view.
/// A run without `origin` is a CLI run.
@MainActor
@Suite struct ActionOriginTests {
    func run(_ params: [String: JSONValue]) async -> (Result<JSONValue, ControlError>, ActionInvocation?) {
        let registry = ActionRegistry.standard()
        var seen: ActionInvocation?
        registry.bind("splitRight", invoke: { seen = $0 })
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, settings: nil, configuration: .loadTolerant)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        var all = params
        all["action"] = .string("splitRight")
        let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: all))
        return (result, seen)
    }

    /// Expects exactly the person-only refusal. A timeout is a harness
    /// failure (the handler never ran), never a refusal.
    func expectPersonOnlyRefusal(_ result: Result<JSONValue, ControlError>, _ context: String,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        switch result {
        case .success(let value):
            Issue.record("\(context): expected the person-only refusal, got success \(value)", sourceLocation: sourceLocation)
        case .failure(let error) where error.code == "timeout":
            Issue.record("\(context): timeout, handler never ran (harness load, not a refusal): \(error.message)",
                         sourceLocation: sourceLocation)
        case .failure(let error):
            #expect(error.code == "unavailable", "\(context)", sourceLocation: sourceLocation)
            #expect(error.data?["reason"] == .string(ControlStrings.text("control.error.personOnly", "Only a person in cmux can run this action")),
                    "\(context)", sourceLocation: sourceLocation)
        }
    }

    @Test func aRunWithoutOriginIsTheCLIAndChangesNoView() async throws {
        let (result, invocation) = await run([:])
        _ = try result.get()
        #expect(invocation?.origin == .cli)
        #expect(invocation?.allowsViewChange == false)
    }

    @Test func focusTrueOrAUserOriginAllowsAViewChange() async throws {
        let (_, asked) = await run(["focus": true])
        #expect(asked?.allowsViewChange == true)
        let (_, user) = await run(["origin": "user"])
        #expect(user?.origin == .user)
        #expect(user?.allowsViewChange == true)
        let (_, agent) = await run(["origin": "mcp"])
        #expect(agent?.allowsViewChange == false)
    }

    @Test func anUnknownOriginIsRefused() async {
        let (result, invocation) = await run(["origin": "robot"])
        guard case .failure(let error) = result else {
            Issue.record("expected invalid params")
            return
        }
        #expect(error.code == "invalid_params")
        #expect(invocation == nil)
    }

    /// `action.list` and `action.describe` say which actions focus by purpose.
    @Test func describeReportsWhetherTheActionFocuses() async throws {
        let registry = ActionRegistry.standard()
        let router = ControlRouter(identity: testIdentity(), executor: RegistryControlBridge(registry: registry), settings: nil, configuration: .loadTolerant)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        let focus = try await router.handle(ControlRequest(id: "1", method: "action.describe", params: ["action": "app show-tab"])).get()
        #expect(focus["action"]?["focuses"] == true)
        let split = try await router.handle(ControlRequest(id: "2", method: "action.describe", params: ["action": "splitRight"])).get()
        #expect(split["action"]?["focuses"] == false)
        let list = try await router.handle(ControlRequest(id: "3", method: "action.list", params: [:])).get()
        let focusing = list["actions"]?.arrayValue?.filter { $0["focuses"] == true }.compactMap { $0["id"]?.stringValue } ?? []
        #expect(focusing.contains("tab.focus") && focusing.contains("focusLeft") && !focusing.contains("newTab"))
        // Open Chief Subagent shows a subagent's tab or opens a workspace on it: a view change.
        #expect(focusing.contains("chief.openSubagent"))
    }

    /// Import Passwords from CSV is a person's: the socket refuses it even
    /// when the caller claims to be the user, and the handler never runs.
    @Test func thePasswordCSVImportIsRefusedOverTheSocket() async {
        let registry = ActionRegistry.standard()
        var ran = false
        registry.bind("password.importCSV", invoke: { _ in ran = true })
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, settings: nil,
                                   configuration: .loadTolerant)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        for origin: JSONValue in ["user", "cli", "mcp", .null] {
            let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
                "action": "password.importCSV", "origin": origin,
            ]))
            expectPersonOnlyRefusal(result, "password.importCSV from \(origin)")
        }
        #expect(!ran)
        #expect(registry.descriptor(for: "password.importCSV")?.isPersonOnly == true)
    }

    /// Import from Browser opens the import with its password consent screen:
    /// only a person starts it (PASSWORDS-IMPORT-ANY-BROWSER), so the socket
    /// refuses it from every origin and it has no `cmux browser` verb.
    @Test func theBrowserImportIsRefusedOverTheSocket() async {
        let registry = ActionRegistry.standard()
        var ran = false
        registry.bind("importFromBrowser", invoke: { _ in ran = true })
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, settings: nil,
                                   configuration: .loadTolerant)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        for origin: JSONValue in ["user", "cli", "mcp", .null] {
            let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
                "action": "importFromBrowser", "origin": origin,
            ]))
            expectPersonOnlyRefusal(result, "importFromBrowser from \(origin)")
        }
        #expect(!ran)
        #expect(registry.descriptor(for: "importFromBrowser")?.cliName != "browser import-data")
    }

    /// Loading unpacked code stays available to a person through the palette,
    /// menu, and keyboard, but every automated control origin is refused.
    @Test func loadingAnUnpackedExtensionIsRefusedOverTheSocket() async {
        let registry = ActionRegistry.standard()
        registry.context = [.browserFocused]
        var ran = false
        registry.bind("browser.extensions.loadUnpacked", invoke: { _ in ran = true })
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, settings: nil,
                                   configuration: .loadTolerant)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        for origin: JSONValue in ["user", "cli", "mcp", "script", .null] {
            let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
                "action": "browser.extensions.loadUnpacked", "origin": origin,
                "target": "pane:test", "args": ["path": "/tmp/test-extension"],
            ]))
            expectPersonOnlyRefusal(result, "browser.extensions.loadUnpacked from \(origin)")
        }
        #expect(!ran)
        #expect(registry.descriptor(for: "browser.extensions.loadUnpacked")?.isPersonOnly == true)
        #expect(registry.perform(
            "browser.extensions.loadUnpacked",
            invocation: ActionInvocation(
                target: ActionTargetRef(kind: .pane, id: "test"),
                arguments: ["path": .string("/tmp/test-extension")]
            )
        ))
        #expect(ran, "an in-app palette, menu, or keyboard run still reaches the handler")
    }

    /// Raw page captures give a browser page's own pixels. Automation must use
    /// the browser host's guarded capture, which masks secrets in every frame,
    /// instead of bypassing it through the generic action socket. Design mode
    /// also snapshots selected page regions into a composer, so only a person
    /// may enable that capture path. Window, pane and tab screenshots run for
    /// automation with every page masked
    /// (``windowPaneAndTabScreenshotsRunOverTheSocketAsAutomation()``).
    @Test func rawPageCapturesAreRefusedOverTheSocket() async {
        let registry = ActionRegistry.standard()
        registry.context = [.browserFocused, .webViewFocused]
        let ids: [ActionID] = [
            "browserScreenshotPage", "browserScreenshotSection",
            "devtools.captureScreenshot", "devtools.captureFullPageScreenshot", "devtools.captureNodeScreenshot",
            "toggleBrowserDesignMode",
        ]
        var ran: [ActionID] = []
        for id in ids { registry.bind(id, invoke: { _ in ran.append(id) }) }
        let router = ControlRouter(identity: testIdentity(), executor: RegistryControlBridge(registry: registry), settings: nil,
                                   configuration: .loadTolerant)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))

        for id in ids {
            for origin: JSONValue in ["user", "cli", "mcp", "script", .null] {
                let result = await router.handle(ControlRequest(method: "action.run", params: [
                    "action": .string(id.rawValue), "origin": origin,
                ]))
                expectPersonOnlyRefusal(result, "\(id) from \(origin)")
            }
        }
        #expect(ran.isEmpty)
        for id in ids { #expect(registry.descriptor(for: id)?.isPersonOnly == true) }
    }

    /// An agent's or a script's window, pane or tab screenshot runs (Leo 2026-10-21: agents
    /// need before/after captures of the real app) and reaches the handler marked as a socket
    /// run, whatever origin it claims, `user` included: the handler then masks every browser
    /// page and chat (ActionInvocation.isPersonsOwnRun, MaskedScreenshotTests in the app tests).
    /// Only a run from inside the app is unmarked.
    @Test func windowPaneAndTabScreenshotsRunOverTheSocketAsAutomation() async throws {
        let registry = ActionRegistry.standard()
        registry.context = [.browserFocused, .webViewFocused]
        let ids: [ActionID] = ["window.screenshot", "pane.screenshot", "tab.screenshot"]
        var runs: [(ActionID, ActionInvocation)] = []
        for id in ids { registry.bind(id, invoke: { runs.append((id, $0)) }) }
        let router = ControlRouter(identity: testIdentity(), executor: RegistryControlBridge(registry: registry), settings: nil,
                                   configuration: .loadTolerant)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))

        let origins: [JSONValue] = ["user", "cli", "mcp", "script", .null]
        for id in ids {
            #expect(registry.descriptor(for: id)?.isPersonOnly == false, "\(id)")
            for origin in origins {
                let result = await router.handle(ControlRequest(method: "action.run", params: [
                    "action": .string(id.rawValue), "origin": origin,
                ]))
                _ = try result.get()
            }
        }
        #expect(runs.map { $0.0 } == ids.flatMap { Array(repeating: $0, count: origins.count) })
        #expect(runs.allSatisfy { $0.1.viaControlSocket }, "every socket run is marked, a claimed user origin included")
        #expect(runs.contains { $0.1.origin == .user }, "the claim itself still reaches the handler")

        runs.removeAll()
        #expect(registry.perform("window.screenshot", invocation: ActionInvocation()))
        #expect(runs.first?.1.viaControlSocket == false, "a palette, menu or keyboard run is the person's own")
    }

    @Test func toolPermissionActionsRequireAPersonInTheApp() async {
        let registry = ActionRegistry.standard()
        registry.context = [.agentPaneFocused]
        let ids: [ActionID] = ["allowOnce", "allowChat", "deny", "expand", "retry", "revoke", "refresh"]
            .map { ActionID(rawValue: "agentPane.permission.\($0)") }
        var ran: [ActionID] = []
        for id in ids { registry.bind(id, invoke: { _ in ran.append(id) }) }
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, settings: nil,
                                   configuration: .loadTolerant)
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))

        for id in ids {
            for origin: JSONValue in ["user", "cli", "mcp", "script", .null] {
                let result = await router.handle(ControlRequest(method: "action.run", params: [
                    "action": .string(id.rawValue), "origin": origin, "target": "pane:test",
                ]))
                expectPersonOnlyRefusal(result, "\(id) from \(origin)")
            }
        }
        #expect(ran.isEmpty)
        for id in ids { #expect(registry.perform(id)) }
        #expect(ran == ids)
    }

    @Test func inAppRunsAreTheUsers() {
        #expect(ActionInvocation().origin == .user)
        #expect(ActionInvocation().allowsViewChange)
    }
}
