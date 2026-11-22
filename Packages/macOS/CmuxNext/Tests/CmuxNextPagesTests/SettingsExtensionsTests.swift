@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Settings > Advanced > Extensions' host: the meter is `cmux --json apps meters`, a bisect step is
/// `cmux --json safe-mode bisect STEP`, a step that changes what runs needs the person's gesture,
/// and a refusal comes back as the CLI's words.
@MainActor @Suite struct SettingsExtensionsTests {
    typealias Runs = SettingsExtensionsRuns

    static let page = PageCallContext(page: "cmux.settings")
    static let click = PageCallContext(page: "cmux.settings", userGesture: true, gestureEvent: 1)

    func extensions(_ runs: Runs) -> SettingsExtensions {
        SettingsExtensions(cli: { URL(fileURLWithPath: "/bin/cmux") }, runCLI: { _, arguments in
            runs.arguments.append(arguments)
            return runs.answer
        })
    }

    @Test func theMeterAndStatusReadWithoutAGesture() async throws {
        let runs = Runs()
        let provider = extensions(runs)
        let answer = try await provider.call(SettingsExtensions.op, params: ["verb": "meters"], context: Self.page)
        _ = try await provider.call(SettingsExtensions.op, params: ["verb": "status"], context: Self.page)
        #expect(runs.arguments == [["--json", "apps", "meters"], ["--json", "safe-mode", "bisect", "status"]])
        #expect(answer["meters"] != nil)
    }

    @Test func eachBisectStepIsOneCLIRunOnAClick() async throws {
        let runs = Runs()
        let provider = extensions(runs)
        for verb in ["start", "good", "bad", "reset"] {
            _ = try await provider.call(SettingsExtensions.op, params: ["verb": .string(verb)], context: Self.click)
        }
        #expect(runs.arguments == ["start", "good", "bad", "reset"].map { ["--json", "safe-mode", "bisect", $0] })
    }

    @Test func aStepWithoutThePersonsGestureOrAnUnknownVerbRunsNothing() async throws {
        let runs = Runs()
        let provider = extensions(runs)
        await #expect(throws: PageError.self) {
            try await provider.call(SettingsExtensions.op, params: ["verb": "start"], context: Self.page)
        }
        for verb in ["on", "off", "--help", ""] {
            await #expect(throws: PageError.self) {
                try await provider.call(SettingsExtensions.op, params: ["verb": .string(verb)], context: Self.click)
            }
        }
        #expect(runs.arguments.isEmpty)
    }

    @Test func aRefusalIsTheCLIsWords() async throws {
        let runs = Runs()
        runs.answer = (1, Data(), Data("cmux: apps.safe_mode.off: safe mode is off\n".utf8))
        let answer = try await extensions(runs).call(SettingsExtensions.op, params: ["verb": "start"], context: Self.click)
        #expect(answer["code"]?.stringValue == "apps.safe_mode.off")
        #expect(answer["message"]?.stringValue == "safe mode is off")
        let plain = SettingsExtensions.refusal(Data("cmux: a bisect needs cmux running in safe mode (no socket)".utf8))
        #expect(plain["code"]?.stringValue == "cmux.settings.extensions")
    }
}

/// What the fake CLI saw and answers; the runner closure is `@Sendable` and runs off the main actor.
nonisolated final class SettingsExtensionsRuns: @unchecked Sendable {
    var arguments: [[String]] = []
    var answer: (Int32, Data, Data) = (0, Data(#"{"meters":[]}"#.utf8), Data())
}
