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
// Named so check-action-surfaces.sh's `ActionContractTests` filter runs it on every catalog change.
@Suite struct ArgumentActionContractTests {
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
        let request = try Self.validated(Self.info(descriptor), [given: .string("p-1"), "prompt": .string("hi"), "agent": .string("claude")])
        #expect(request.arguments["promptId"] != nil)
        #expect(request.arguments.count == 3)
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

    /// Two spellings of one argument in one request are refused, never one silently winning.
    @Test func twoSpellingsOfOneArgumentAreRefused() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == "cloudRelayChat" })
        let args: [String: JSONValue] = ["promptId": .string("p-1"), "prompt-id": .string("p-2"),
                                         "prompt": .string("hi"), "agent": .string("claude")]
        #expect(throws: ControlError.self) { try Self.validated(Self.info(descriptor), args) }
    }

    /// The requests the CLI's own encoder builds (cmux-tui `cli/tests/action_argument_contract.rs` writes
    /// them to cmux-tui/spec/fixtures/cli-action-requests.json: `cmux cloud start-chat`'s relay request as the
    /// CLI sends it, and one request per CLI action with every argument given as its `--flag`) pass the
    /// app's own validation under the catalog's exact names, no alias folding. `--prompt-id` reaching an
    /// argument named `prompt-id` as `promptId` fails here.
    @Test func everyRequestTheCLIEncodesValidatesAgainstTheCatalog() throws {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no cmux-tui/spec above \(#filePath)")
            root = parent
        }
        let data = try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/fixtures/cli-action-requests.json"))
        let fixture = try JSONDecoder().decode([String: JSONValue].self, from: data)
        guard case .array(let requests) = try #require(fixture["requests"]) else {
            Issue.record("cli-action-requests.json has no requests array")
            return
        }
        #expect(requests.count > 50, "only \(requests.count) CLI requests; is the fixture stale?")
        let byID = Dictionary(ActionCatalog.all.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        let byCLI = Dictionary(ActionCatalog.all.map { ($0.cliName, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in requests {
            guard case .object(let row) = entry, case .object(let params)? = row["params"],
                  let action = params["action"]?.stringValue else {
                Issue.record("a malformed request: \(entry)")
                continue
            }
            let source = row["source"]?.stringValue ?? action
            guard let descriptor = byID[action] ?? byCLI[action] else {
                Issue.record("\(source): the CLI runs '\(action)', which the app has no action for")
                continue
            }
            let names = Set(descriptor.arguments.map(\.name))
            if case .object(let args)? = params["args"] {
                for key in args.keys where !names.contains(key) {
                    Issue.record("\(source): \(descriptor.id.rawValue) has no argument '\(key)' (it takes \(names.sorted()))")
                }
            }
            var checked = params
            checked["origin"] = nil
            #expect(throws: Never.self, "\(source)") {
                try ControlRouter.validatedRequest(for: Self.info(descriptor), params: checked,
                                                   knownKinds: ActionTargetKind.allCases.map(\.rawValue),
                                                   connection: ControlConnectionID(rawValue: 1))
            }
        }
    }
}
