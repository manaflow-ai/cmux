@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Settings > Appearance > Looks' host: each page call becomes one `cmux --json setup` run with every
/// id as its own argument, a change runs only on the person's gesture, and an install with no `yes`
/// asks the CLI for its card without writing anything.
@MainActor @Suite struct SettingsLooksTests {
    typealias Runs = SettingsCustomizeLibraryRuns

    static let page = PageCallContext(page: "cmux.settings")
    static let click = PageCallContext(page: "cmux.settings", userGesture: true, gestureEvent: 1)

    func looks(_ runs: Runs) -> SettingsLooks {
        SettingsLooks(cli: { URL(fileURLWithPath: "/bin/cmux") },
                      settingsFile: { URL(fileURLWithPath: "/tmp/cmux-next.json") },
                      runCLI: { _, arguments, environment in
                          runs.arguments.append(arguments)
                          runs.configFiles.append(environment["CMUX_NEXT_CONFIG_FILE"])
                          return runs.answer
                      })
    }

    @Test func galleryAndPreviewReadWithoutAGesture() async throws {
        let runs = Runs()
        let provider = looks(runs)
        _ = try await provider.call(SettingsLooks.op, params: ["verb": "gallery"], context: Self.page)
        _ = try await provider.call(SettingsLooks.op, params: ["verb": "preview", "id": "manaflow-ai/paper-look", "scheme": "light"], context: Self.page)
        _ = try await provider.call(SettingsLooks.op, params: ["verb": "preview", "id": "manaflow-ai/paper-look"], context: Self.page)
        #expect(runs.arguments == [
            ["--json", "setup", "gallery"],
            ["--json", "setup", "preview", "manaflow-ai/paper-look", "--scheme", "light"],
            ["--json", "setup", "preview", "manaflow-ai/paper-look", "--scheme", "dark"],
        ])
        #expect(runs.configFiles.allSatisfy { $0 == "/tmp/cmux-next.json" })
    }

    @Test func eachChangeIsOneSetupVerb() async throws {
        let runs = Runs()
        let provider = looks(runs)
        for params: JSONValue in [
            ["verb": "install", "reference": "github.com/manaflow-ai/cmux-paper-look"],
            ["verb": "install", "reference": "github.com/manaflow-ai/cmux-paper-look@e983f57", "yes": true],
            ["verb": "off", "id": "manaflow-ai/paper-look"],
            ["verb": "on", "id": "manaflow-ai/paper-look"],
            ["verb": "order", "ids": ["manaflow-ai/studio-look", "manaflow-ai/paper-look"]],
            ["verb": "remove", "id": "manaflow-ai/paper-look"],
        ] {
            _ = try await provider.call(SettingsLooks.op, params: params, context: Self.click)
        }
        #expect(runs.arguments == [
            ["--json", "setup", "install", "github.com/manaflow-ai/cmux-paper-look"],
            ["--json", "setup", "install", "github.com/manaflow-ai/cmux-paper-look@e983f57", "--yes"],
            ["--json", "setup", "off", "manaflow-ai/paper-look"],
            ["--json", "setup", "on", "manaflow-ai/paper-look"],
            ["--json", "setup", "order", "manaflow-ai/studio-look", "manaflow-ai/paper-look"],
            ["--json", "setup", "remove", "manaflow-ai/paper-look"],
        ])
    }

    @Test func aChangeWithoutAGestureRunsNothing() async {
        let runs = Runs()
        let provider = looks(runs)
        await #expect(throws: PageError.self) {
            _ = try await provider.call(SettingsLooks.op, params: ["verb": "install", "reference": "github.com/o/r", "yes": true], context: Self.page)
        }
        #expect(runs.arguments.isEmpty)
    }

    @Test func aFlagNeverPassesAsAnId() async {
        let runs = Runs()
        let provider = looks(runs)
        for params: JSONValue in [
            ["verb": "remove", "id": "--all"],
            ["verb": "install", "reference": "-y"],
            ["verb": "order", "ids": ["a/b", "--x"]],
            ["verb": "order", "ids": []],
            ["verb": "nope"],
        ] {
            await #expect(throws: PageError.self) {
                _ = try await provider.call(SettingsLooks.op, params: params, context: Self.click)
            }
        }
        #expect(runs.arguments.isEmpty)
    }

    @Test func aRefusalAnswersTheCLIsEnvelope() async throws {
        let runs = Runs()
        runs.answer = (1, Data(), Data(#"{"code":"setup.needs_consent","message":"show the card","details":{"commit":"e983f57"}}"#.utf8))
        let answer = try await looks(runs).call(SettingsLooks.op, params: ["verb": "install", "reference": "github.com/o/r"], context: Self.click)
        #expect(answer["code"]?.stringValue == "setup.needs_consent")
        #expect(answer["details"]?["commit"]?.stringValue == "e983f57")
    }
}
