@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Settings > Appearance > Customization Library's host: each page call becomes one
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
        let defaultFile = URL(fileURLWithPath: "/Users/someone/.config/cmux-next/cmux-next.json")
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

    @Test func theDoctorVerbsAreTheCLIsWithTheIdAsItsOwnArgument() async throws {
        let runs = Runs()
        let provider = library(runs)
        _ = try await provider.call(SettingsCustomizeLibrary.op, params: ["verb": "doctor"], context: Self.page)
        for params: JSONValue in [
            ["verb": "doctor-fix", "id": "layer-on:pr-45206", "fix": "off"],
            ["verb": "doctor-fix", "id": "leftover:themes/old", "fix": "remove"],
            ["verb": "doctor-fix", "id": "broken:themes/night.json", "fix": "restore"],
            ["verb": "doctor-fix", "id": "shadowed:appearance.theme", "fix": "follow-default"],
            ["verb": "doctor-dismiss", "id": "broken:themes/night.json"],
            ["verb": "doctor-recover"],
        ] {
            _ = try await provider.call(SettingsCustomizeLibrary.op, params: params, context: Self.click)
        }
        #expect(runs.arguments == [
            ["--json", "customize", "doctor"],
            ["--json", "customize", "doctor", "fix", "layer-on:pr-45206", "off"],
            ["--json", "customize", "doctor", "fix", "leftover:themes/old", "remove"],
            ["--json", "customize", "doctor", "fix", "broken:themes/night.json", "restore"],
            ["--json", "customize", "doctor", "fix", "shadowed:appearance.theme", "follow-default"],
            ["--json", "customize", "doctor", "dismiss", "broken:themes/night.json"],
            ["--json", "customize", "doctor", "recover"],
        ])
    }

    @Test func aDoctorChangeNeedsTheGestureAndABadIdOrFixRunsNothing() async throws {
        let runs = Runs()
        let provider = library(runs)
        for params: JSONValue in [
            ["verb": "doctor-fix", "id": "layer-on:pr-1", "fix": "off"],
            ["verb": "doctor-dismiss", "id": "layer-on:pr-1"],
            ["verb": "doctor-open", "id": "broken:themes/night.json"],
            ["verb": "doctor-recover"],
        ] {
            await #expect(throws: PageError.self) {
                try await provider.call(SettingsCustomizeLibrary.op, params: params, context: Self.page)
            }
        }
        for params: JSONValue in [
            ["verb": "doctor-fix", "id": "--all", "fix": "off"],
            ["verb": "doctor-fix", "id": "layer-on:pr-1", "fix": "open"],
            ["verb": "doctor-fix", "id": "layer-on:pr-1"],
            ["verb": "doctor-dismiss", "id": ""],
            ["verb": "doctor-dismiss"],
            ["verb": "doctor-open", "id": "-x"],
        ] {
            await #expect(throws: PageError.self) {
                try await provider.call(SettingsCustomizeLibrary.op, params: params, context: Self.click)
            }
        }
        #expect(runs.arguments.isEmpty)
    }

    @Test func doctorOpenReadsTheReportAndOpensTheFindingsPath() async throws {
        let runs = Runs()
        runs.answer = (0, Data(#"""
        {"doctor":{"findings":[
          {"id":"layer-on:pr-1","path":null},
          {"id":"broken:themes/night.json","path":"/tmp/cmux-doctor-test/night.json"}
        ],"line":null,"announce":null}}
        """#.utf8), Data())
        var opened: [URL] = []
        let provider = SettingsCustomizeLibrary(cli: { URL(fileURLWithPath: "/bin/cmux") }, settingsFile: { nil },
                                                runCLI: { _, arguments, _ in
                                                    runs.arguments.append(arguments)
                                                    return runs.answer
                                                },
                                                open: { url, _ in opened.append(url) })
        let answer = try await provider.call(SettingsCustomizeLibrary.op, params: ["verb": "doctor-open", "id": "broken:themes/night.json"],
                                             context: Self.click)
        #expect(runs.arguments == [["--json", "customize", "doctor"]])
        #expect(opened == [URL(fileURLWithPath: "/tmp/cmux-doctor-test/night.json")])
        #expect(answer["opened"]?.stringValue == "/tmp/cmux-doctor-test/night.json")
        // A finding with no path, or no such finding, opens nothing.
        for id in ["layer-on:pr-1", "unknown:x"] {
            await #expect(throws: PageError.self) {
                try await provider.call(SettingsCustomizeLibrary.op, params: ["verb": "doctor-open", "id": .string(id)], context: Self.click)
            }
        }
        #expect(opened.count == 1)
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
/// Settings > General's Customize cmux checklist: a read with no gesture, each connection the page
/// reports one `--has NAME`, and a name the CLI does not know refused before any run.
@MainActor @Suite struct SettingsCustomizeChecklistTests {
    @Test func theChecklistReadsWithTheConnectionsThePageReports() async throws {
        let runs = SettingsCustomizeLibraryRuns()
        let provider = SettingsCustomizeLibraryTests().library(runs)
        _ = try await provider.call(SettingsCustomizeLibrary.checklistOp, params: ["has": ["github", "models"]],
                                    context: SettingsCustomizeLibraryTests.page)
        _ = try await provider.call(SettingsCustomizeLibrary.checklistOp, params: [:], context: SettingsCustomizeLibraryTests.page)
        #expect(runs.arguments == [
            ["--json", "customize", "checklist", "--has", "github", "--has", "models"],
            ["--json", "customize", "checklist"],
        ])
        await #expect(throws: PageError.self) {
            try await provider.call(SettingsCustomizeLibrary.checklistOp, params: ["has": ["--json"]],
                                    context: SettingsCustomizeLibraryTests.page)
        }
        #expect(runs.arguments.count == 2)
    }
}

nonisolated final class SettingsCustomizeLibraryRuns: @unchecked Sendable {
    var arguments: [[String]] = []
    var configFiles: [String?] = []
    var answer: (Int32, Data, Data) = (0, Data(#"{"library":{"entries":[],"conflicts":[]}}"#.utf8), Data())
}
