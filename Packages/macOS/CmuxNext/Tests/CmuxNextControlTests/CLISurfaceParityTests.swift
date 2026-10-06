import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// The CLI side of the surface parity rule (plans/cmux-next/actions.md):
/// every action the catalog offers on the CLI runs from `action.run` by
/// its CLI name, reaches its own handler through `ActionRegistry.perform`,
/// and carries the caller's origin; `action.list` reports every surface.
@MainActor
@Suite struct CLISurfaceParityTests {
    static func value(for argument: ActionArgument) -> JSONValue {
        switch argument.kind {
        case .string: .string("x")
        case .int(let range): .number(Double(range?.lowerBound ?? 1))
        case .bool: .bool(true)
        case .enumeration(let cases): .string(cases.first?.value ?? "")
        case .target(let kind): .string("\(kind.rawValue):t1")
        }
    }

    @Test func everyCLIActionRunsItsOwnHandlerByCLIName() async throws {
        let registry = ActionRegistry.standard()
        var runs: [(ActionID, ActionInvocation)] = []
        for descriptor in ActionCatalog.all {
            let id = descriptor.id
            registry.bind(id, invoke: { runs.append((id, $0)) })
        }
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: testIdentity(), executor: bridge, settings: nil, configuration: .loadTolerant)
        var catalog = RegistryControlBridge.catalog(from: registry)
        catalog.contextMask = .max
        router.updateCatalog(catalog)
        registry.context = ActionContext(rawValue: .max)
        let offered = ActionCatalog.all.filter { $0.surfacePlan.cli?.isOffered == true }
        #expect(offered.count > 300)
        for descriptor in offered {
            var arguments: [String: JSONValue] = [:]
            for argument in descriptor.arguments where argument.isRequired || argument.name == ActionArgument.confirmName {
                arguments[argument.name] = Self.value(for: argument)
            }
            var params: [String: JSONValue] = ["action": .string(descriptor.cliName), "origin": .string("script")]
            if !arguments.isEmpty { params["args"] = .object(arguments) }
            runs.removeAll()
            let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: params))
            if case .failure(let error) = result {
                Issue.record("\(descriptor.cliName) (\(descriptor.id)): \(error.code) \(error.message)")
                continue
            }
            #expect(runs.first?.0 == descriptor.id, "\(descriptor.cliName) ran \(String(describing: runs.first?.0))")
            #expect(runs.first?.1.origin == .script, "\(descriptor.id) origin")
        }
    }

    @Test func actionListReportsEverySurface() throws {
        let registry = ActionRegistry.standard()
        let catalog = RegistryControlBridge.catalog(from: registry)
        for action in catalog.actions {
            guard case .object(let members) = action.json(contextMask: 0, debugActionsAvailable: true),
                  case .object(let surfaces)? = members["surfaces"]
            else {
                Issue.record("\(action.id): no surfaces")
                continue
            }
            for key in ["palette", "cli", "context_menu", "mcp", "context_menus"] {
                #expect(surfaces[key] != nil, "\(action.id): \(key)")
            }
        }
    }
}
