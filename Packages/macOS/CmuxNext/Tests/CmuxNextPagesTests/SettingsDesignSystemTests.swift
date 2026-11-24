@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Settings > Design System's host: one `cmux --json ext design --show --scene` run on the app's
/// settings file, answered as the CLI printed it; a CLI that fails is the page's Unavailable line.
@MainActor @Suite struct SettingsDesignSystemTests {
    static let page = PageCallContext(page: "cmux.settings")

    func part(_ runs: SettingsCustomizeLibraryRuns) -> SettingsDesignSystem {
        SettingsDesignSystem(cli: { URL(fileURLWithPath: "/bin/cmux") },
                             settingsFile: { URL(fileURLWithPath: "/tmp/cmux-next.json") },
                             runCLI: { _, arguments, environment in
                                 runs.arguments.append(arguments)
                                 runs.configFiles.append(environment["CMUX_NEXT_CONFIG_FILE"])
                                 return runs.answer
                             })
    }

    @Test func readsTheResolvedSystemAndItsSceneWithoutAGesture() async throws {
        let runs = SettingsCustomizeLibraryRuns()
        runs.answer = (0, Data(#"{"layers":[{"kind":"cmux","file":"cmux","applied":true}],"changed":[],"design":[],"note":"n","scene":[]}"#.utf8), Data())
        let answer = try await part(runs).call(SettingsDesignSystem.op, params: [:], context: Self.page)
        #expect(runs.arguments == [["--json", "ext", "design", "--show", "--scene"]])
        #expect(runs.configFiles == ["/tmp/cmux-next.json"])
        #expect(answer["scene"] != nil)
        #expect(answer["layers"]?.arrayValue?.first?["kind"]?.stringValue == "cmux")
    }

    @Test func aFailedRunIsUnavailableInTheCLIsWords() async {
        let runs = SettingsCustomizeLibraryRuns()
        runs.answer = (5, Data(), Data("cmux: the design view did not load\n".utf8))
        await #expect(throws: PageError.self) {
            _ = try await part(runs).call(SettingsDesignSystem.op, params: [:], context: Self.page)
        }
        await #expect(throws: PageError.self) {
            _ = try await part(runs).call("cmux.settings.other", params: [:], context: Self.page)
        }
    }
}
