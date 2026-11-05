import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// The action argument contract between the CLI and the app. The CLI turns every `--flag-name` into
/// `flagName` (cmux-tui `cli/app.rs` `argument_name`), and the catalog is exported with each action's
/// arguments to `plans/cmux-next/action-surfaces.json`, which the Rust contract test
/// (`cli/tests/action_argument_contract.rs`) checks every CLI call site against. `cloud relay-chat` named
/// its argument `prompt-id` while the CLI sent `promptId`, and every `cmux cloud start-chat` failed
/// `invalid_params` (#36193); `new_tab` and `cmux_next` were out of the CLI's reach the same way.
@MainActor
@Suite struct ActionArgumentContractTests {
    static func info(_ descriptor: ActionDescriptor) -> ControlActionInfo {
        ControlActionInfo(id: descriptor.id.rawValue, title: descriptor.title, category: descriptor.category.rawValue,
                          categoryTitle: descriptor.category.title, cliName: descriptor.cliName, symbol: descriptor.symbol,
                          keywords: [], shortcut: nil, shortcutConfig: nil,
                          arguments: descriptor.arguments.map(RegistryControlBridge.argumentInfo),
                          targets: descriptor.targets.map(\.rawValue), requiresMask: 0, requires: [], isBound: true,
                          isDebugOnly: false, mainMenu: nil)
    }

    static func validated(_ action: ControlActionInfo, _ args: [String: JSONValue]) throws -> ControlActionRequest {
        try ControlRouter.validatedRequest(for: action, params: ["args": .object(args)], knownKinds: action.targets,
                                           connection: ControlConnectionID(rawValue: 1))
    }

    /// Every argument is named in lowerCamelCase, the one spelling the CLI's flags reach.
    @Test func everyArgumentNameIsCanonical() {
        for descriptor in ActionCatalog.all {
            for argument in descriptor.arguments {
                #expect(ActionSurfaceExport.isCanonicalArgumentName(argument.name),
                        "\(descriptor.id.rawValue) argument '\(argument.name)' is not lowerCamelCase")
            }
        }
    }

    /// Any spelling of a flag names one argument: no two arguments of an action fold to one name.
    @Test func noTwoArgumentsOfAnActionFoldToOneName() {
        for descriptor in ActionCatalog.all where !descriptor.arguments.isEmpty {
            let names = descriptor.arguments.map(\.name)
            let folded = names.map(ControlRouter.foldedArgumentName)
            #expect(Set(folded).count == folded.count, "\(descriptor.id.rawValue): \(names)")
            #expect(folded == names.map(ActionSurfaceExport.foldedArgumentName), "\(descriptor.id.rawValue)")
        }
    }

    /// The export carries each action's arguments as the router checks them.
    @Test func theExportCarriesEveryArgument() throws {
        for descriptor in ActionCatalog.all {
            let row = ActionSurfaceExport.catalogObject(descriptor, titles: ActionTitleCatalog())
            let args = try #require(row["args"] as? [[String: Any]], "\(descriptor.id.rawValue) exports no args")
            #expect(args.compactMap { $0["name"] as? String } == descriptor.arguments.map(\.name), "\(descriptor.id.rawValue)")
            #expect(args.compactMap { $0["required"] as? Bool } == descriptor.arguments.map(\.isRequired), "\(descriptor.id.rawValue)")
        }
    }

    /// A kebab or snake spelling (an older CLI, a hand-written script) still names the canonical argument
    /// for a release, and arrives under the canonical name.
    @Test(arguments: ["promptId", "prompt-id", "prompt_id"])
    func anySpellingOfAnArgumentNamesIt(_ given: String) throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == "cloudRelayChat" })
        let request = try Self.validated(Self.info(descriptor), [given: .string("p-1"), "prompt": .string("hi")])
        #expect(request.arguments["promptId"] != nil)
        #expect(request.arguments.count == 2)
    }

    /// The renamed snake_case arguments keep their old spelling for a release.
    @Test func theRenamedSnakeCaseArgumentsStillTakeTheirOldNames() throws {
        let renamed = [("history.open", "new_tab", "newTab"), ("palette.installCLI", "cmux_next", "cmuxNext")]
        for (id, old, new) in renamed {
            let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == id })
            var args: [String: JSONValue] = [old: .bool(true)]
            if id == "history.open" { args["id"] = .string("entry-1") }
            let request = try Self.validated(Self.info(descriptor), args)
            #expect(request.arguments[new] != nil, "\(id) took '\(old)' as \(Array(request.arguments.keys))")
            #expect(request.arguments[old] == nil, "\(id)")
        }
    }
}
