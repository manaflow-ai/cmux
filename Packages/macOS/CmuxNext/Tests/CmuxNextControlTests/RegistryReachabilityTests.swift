import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// The action contract's CLI leg: every catalog action is reachable through
/// `action.run` by ID and by CLI name, and every context-menu ID resolves
/// through `action.describe`.
@MainActor
@Suite struct RegistryReachabilityTests {
    /// Every context bit, so no action is filtered as unavailable.
    static let fullContext = ActionContext(rawValue: RegistryControlBridge.contextNames.reduce(0) { $0 | $1.0.rawValue })

    /// A valid argument value for each schema kind.
    static func sampleArguments(_ action: ControlActionInfo) -> JSONValue {
        var arguments: [String: JSONValue] = [:]
        for argument in action.arguments {
            switch argument.kind {
            case .string: arguments[argument.name] = "sample"
            case .int: arguments[argument.name] = JSONValue(argument.range?.lowerBound ?? 1)
            case .bool: arguments[argument.name] = true
            case .enumeration: arguments[argument.name] = .string(argument.choices[0].value)
            case .target: arguments[argument.name] = .string("\(argument.targetKind ?? "tab"):id1")
            }
        }
        return .object(arguments)
    }

    static func runParams(_ action: ControlActionInfo, name: String) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["action": .string(name), "args": sampleArguments(action)]
        if let kind = action.targets.first { params["target"] = .string("\(kind):target1") }
        return params
    }

    @Test func everyActionRunsByIDAndCLINameThroughAFakeExecutor() async throws {
        let registry = ActionRegistry.standard()
        registry.context = Self.fullContext
        var catalog = RegistryControlBridge.catalog(from: registry)
        catalog.debugActionsAvailable = true
        #expect(catalog.actions.count == ActionCatalog.all.count)

        let executor = RecordingExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor)
        router.updateCatalog(catalog)
        for action in catalog.actions {
            for name in [action.id, action.cliName] {
                let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: Self.runParams(action, name: name)))
                switch result {
                case .success(let value):
                    #expect(value["action"] == .string(action.id), "\(name)")
                    #expect(executor.last?.actionID == action.id, "\(name)")
                case .failure(let error):
                    Issue.record("\(name): \(error.code) \(error.message)")
                }
            }
        }
        #expect(executor.requests.withLock { $0.count } == catalog.actions.count * 2)
    }

    @Test func everyActionRunsThroughTheRegistryBridge() async throws {
        let registry = ActionRegistry.standard()
        registry.context = Self.fullContext
        var ran: [ActionID: ActionInvocation] = [:]
        for descriptor in ActionCatalog.all {
            let id = descriptor.id
            registry.bind(id, invoke: { ran[id] = $0 })
        }
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge)
        bridge.attach(to: router)
        defer { bridge.detach() }
        var catalog = router.catalog
        catalog.debugActionsAvailable = true
        router.updateCatalog(catalog)

        for action in router.catalog.actions {
            ran.removeAll()
            let params = Self.runParams(action, name: action.cliName)
            let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: params))
            guard case .success = result else {
                Issue.record("\(action.cliName): \(result)")
                continue
            }
            let invocation = try #require(ran[ActionID(rawValue: action.id)], "\(action.id) handler did not run")
            if let kind = action.targets.first {
                #expect(invocation.target == ActionTargetRef(kind: ActionTargetKind(rawValue: kind)!, id: "target1"), "\(action.id)")
            }
            #expect(invocation.arguments.count == action.arguments.count, "\(action.id)")
        }
    }

    @Test func everyContextMenuIDResolves() async throws {
        let registry = ActionRegistry.standard()
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        for context in ActionMenuContext.allCases {
            for id in ContextMenuCatalog.referencedIDs(ContextMenuCatalog.entries(for: context)) {
                let result = await router.handle(ControlRequest(method: "action.describe", params: ["action": .string(id.rawValue)]))
                #expect((try? result.get())?["action"]?["id"] == .string(id.rawValue), "\(context): \(id)")
            }
        }
    }

    @Test func bridgeReportsUnboundAndPublishesChanges() async throws {
        let registry = ActionRegistry.standard()
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge)
        bridge.attach(to: router)
        defer { bridge.detach() }

        let unbound = await router.handle(ControlRequest(method: "action.run", params: ["action": "workspace-group collapse", "target": "g1"]))
        #expect((unbound.failure)?.code == "not_bound")

        // Binding and overrides reach the snapshot without a manual refresh.
        registry.bind("splitRight") {}
        registry.setShortcutOverride(Shortcut("\\", modifiers: [.command]), for: "splitRight")
        registry.context = [.browserFocused]
        for _ in 0..<100 where router.catalog.contextMask != ActionContext.browserFocused.rawValue || router.catalog.resolve("splitRight")?.isBound != true {
            await Task.yield()
        }
        let info = try #require(router.catalog.resolve("splitRight"))
        #expect(info.isBound)
        #expect(info.shortcut == "⌘\\")
        #expect(info.shortcutConfig == "cmd+\\")
        #expect(router.catalog.contextMask == ActionContext.browserFocused.rawValue)

        let ran = await router.handle(ControlRequest(method: "action.run", params: ["action": .string(info.cliName)]))
        #expect((try? ran.get())?["ran"] == true)
    }
}

extension RegistryReachabilityTests {
    @Test func unavailableAndRefusedReasonsReachTheSocket() async throws {
        let registry = ActionRegistry.standard()
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge)
        registry.bindUnavailable("splitRight", reason: "needs daemon capability viewport-splits-v2")
        registry.bind("splitDown", invoke: { _ in registry.refuse("no pane is focused") })
        bridge.attach(to: router)
        defer { bridge.detach() }

        let gated = await router.handle(ControlRequest(method: "action.run", params: ["action": "splitRight"]))
        #expect(gated.failure?.code == "unavailable")
        #expect(gated.failure?.message.contains("needs daemon capability viewport-splits-v2") == true)

        let refused = await router.handle(ControlRequest(method: "action.run", params: ["action": "splitDown"]))
        #expect(refused.failure?.code == "unavailable")
        #expect(refused.failure?.message.contains("no pane is focused") == true)
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
