@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Settings > Personalization > Customization Library's host: each page call becomes one
/// `cmux --json customize library` run with the name as its own argument, a change runs only on the
/// person's gesture, and a refusal comes back as the CLI's envelope for the page to word.
@MainActor @Suite struct SettingsCustomizeLibraryTests {
    typealias Runs = SettingsCustomizeLibraryRuns

    static let page = PageCallContext(page: "cmux.settings")
    static let click = PageCallContext(page: "cmux.settings", userGesture: true, gestureEvent: 1)

    func library(_ runs: Runs) -> SettingsCustomizeLibrary {
        SettingsCustomizeLibrary(cli: { URL(fileURLWithPath: "/bin/cmux") },
                                 settingsFile: { URL(fileURLWithPath: "/tmp/cmux-next.json") },
                                 runCLI: { _, arguments, environment in
                                     runs.arguments.append(arguments)
                                     runs.configFiles.append(environment["CMUX_NEXT_CONFIG_FILE"])
                                     return runs.answer
                                 })
    }

    @Test func listReadsWithoutAGestureAndOnTheAppsSettingsFile() async throws {
        let runs = Runs()
        let answer = try await library(runs).call(SettingsCustomizeLibrary.op, params: ["verb": "list"], context: Self.page)
        #expect(runs.arguments == [["--json", "customize", "library", "list"]])
        #expect(runs.configFiles == ["/tmp/cmux-next.json"])
        #expect(answer["library"]?["entries"] != nil)
    }

    /// An override moves the CLI's library state into the config folder, so the app's default file
    /// is never named: the card then lists what an ordinary `cmux customize` run kept (review P1-F1).
    @Test func theDefaultSettingsFileKeepsTheCLIsOwnStateFolder() {
        let home = ["HOME": "/Users/someone"]
        let defaultFile = URL(fileURLWithPath: "/Users/someone/.config/cmux/cmux-next.json")
        #expect(SettingsCustomizeLibrary.environment(home, settingsFile: defaultFile)["CMUX_NEXT_CONFIG_FILE"] == nil)
        #expect(SettingsCustomizeLibrary.environment(home, settingsFile: nil)["CMUX_NEXT_CONFIG_FILE"] == nil)
        let tagged = URL(fileURLWithPath: "/tmp/tagged/cmux-next.json")
        #expect(SettingsCustomizeLibrary.environment(home, settingsFile: tagged)["CMUX_NEXT_CONFIG_FILE"] == "/tmp/tagged/cmux-next.json")
        // A launch override the app inherited stays when the app reads the default file.
        let launched = ["HOME": "/Users/someone", "CMUX_NEXT_CONFIG_FILE": "/tmp/own.json"]
        #expect(SettingsCustomizeLibrary.environment(launched, settingsFile: defaultFile)["CMUX_NEXT_CONFIG_FILE"] == "/tmp/own.json")
    }

    @Test func eachChangeIsOneCLIVerbWithTheNameAsItsOwnArgument() async throws {
        let runs = Runs()
        let provider = library(runs)
        for params: JSONValue in [
            ["verb": "on", "name": "night"],
            ["verb": "off", "name": "night"],
            ["verb": "order", "name": "night", "position": "2"],
            ["verb": "order", "name": "night", "position": "top"],
            ["verb": "remove", "name": "night owl"],
        ] {
            _ = try await provider.call(SettingsCustomizeLibrary.op, params: params, context: Self.click)
        }
        #expect(runs.arguments == [
            ["--json", "customize", "library", "on", "night"],
            ["--json", "customize", "library", "off", "night"],
            ["--json", "customize", "library", "order", "night", "2"],
            ["--json", "customize", "library", "order", "night", "top"],
            ["--json", "customize", "library", "remove", "night owl"],
        ])
    }

    @Test func aChangeWithoutThePersonsGestureIsRefusedAndNothingRuns() async throws {
        let runs = Runs()
        await #expect(throws: PageError.self) {
            try await library(runs).call(SettingsCustomizeLibrary.op, params: ["verb": "off", "name": "night"], context: Self.page)
        }
        #expect(runs.arguments.isEmpty)
    }

    @Test func aFlagANameOrAPositionTheCLIWouldMisreadIsRefused() async throws {
        let runs = Runs()
        let provider = library(runs)
        for params: JSONValue in [
            ["verb": "on", "name": "--link"],
            ["verb": "on"],
            ["verb": "order", "name": "night", "position": "0"],
            ["verb": "order", "name": "night", "position": "-1"],
            ["verb": "order", "name": "night"],
            ["verb": "export", "name": "night"],
            ["verb": "import", "name": "/etc/hosts"],
        ] {
            await #expect(throws: PageError.self) {
                try await provider.call(SettingsCustomizeLibrary.op, params: params, context: Self.click)
            }
        }
        #expect(runs.arguments.isEmpty)
    }

    @Test func aRefusalIsTheCLIsEnvelope() async throws {
        let runs = Runs()
        runs.answer = (1, Data(), Data(#"{"code":"customize.library","message":"a preview is open"}"#.utf8))
        let answer = try await library(runs).call(SettingsCustomizeLibrary.op, params: ["verb": "on", "name": "night"],
                                                  context: Self.click)
        #expect(answer["code"]?.stringValue == "customize.library")
        #expect(answer["message"]?.stringValue == "a preview is open")
    }
}

/// What the fake CLI saw and answers. `nonisolated` against the target's MainActor default: the runner
/// closure is `@Sendable` and runs off the main actor. Each test runs its calls one at a time.
nonisolated final class SettingsCustomizeLibraryRuns: @unchecked Sendable {
    var arguments: [[String]] = []
    var configFiles: [String?] = []
    var answer: (Int32, Data, Data) = (0, Data(#"{"library":{"entries":[],"conflicts":[]}}"#.utf8), Data())
}
