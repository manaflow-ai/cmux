@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The sidebar's experiments mark reads the Customization Library through the bundled CLI: it counts
/// only the `pr-N` entries that are on (nothing at all, so no mark, when none is), and its Off runs
/// `customize library off pr-N` for each, the verb the card's switch runs.
@MainActor @Suite struct CustomizeExperimentsTests {
    static func listing(_ entries: [JSONValue]) -> Data {
        let answer: JSONValue = ["library": ["entries": .array(entries), "conflicts": []]]
        return (try? JSONEncoder().encode(answer)) ?? Data()
    }

    static func pr(_ number: Int, on: Bool) -> JSONValue {
        ["name": .string("pr-\(number)"), "on": .bool(on), "source": "pr",
         "code": ["repo": "manaflow-ai/cmux", "pr": .number(Double(number)), "title": "Try a PR", "head": "716063c1d2", "base": "9c1e2f3a4b"]]
    }

    static let night: JSONValue = ["name": "night", "on": true, "source": "ask"]

    /// Lets the read loop run until `done`, up to a 10 s deadline (a broken read fails, never hangs; a busy
    /// runner gets the whole deadline, not a fixed count of reschedules).
    func until(_ done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if done() { return }
            await Task.yield()
        }
    }

    func experiments(_ runs: SettingsCustomizeLibraryRuns) -> CustomizeExperiments {
        CustomizeExperiments(library: SettingsCustomizeLibrary(
            cli: { URL(fileURLWithPath: "/bin/cmux") },
            settingsFile: { nil },
            runCLI: { _, arguments, _ in
                runs.arguments.append(arguments)
                return runs.answer
            }), watch: { _ in })
    }

    @Test func noPullRequestEntryOnMeansNoMark() {
        let none = try? JSONValue.parse(Self.listing([Self.night, Self.pr(43496, on: false)]))
        #expect(CustomizeExperiments.experiments(in: none ?? .null).isEmpty)
        #expect(CustomizeExperiments.line([]) == nil)
        let empty = try? JSONValue.parse(Self.listing([]))
        #expect(CustomizeExperiments.experiments(in: empty ?? .null).isEmpty)
    }

    @Test func onlyThePullRequestEntriesThatAreOnCount() throws {
        let answer = try JSONValue.parse(Self.listing([Self.pr(43543, on: true), Self.night, Self.pr(43496, on: false), Self.pr(43410, on: true)]))
        let on = CustomizeExperiments.experiments(in: answer)
        #expect(on.map(\.name) == ["pr-43543", "pr-43410"])
        #expect(on.first?.repo == "manaflow-ai/cmux")
        #expect(CustomizeExperiments.line(Array(on.prefix(1))) == "Experiment on · #43543")
        #expect(CustomizeExperiments.line(on) == "Experiments on · 2")
    }

    @Test func turnOffRunsTheCardsOffVerbForEachEntryThatIsOn() async throws {
        let runs = SettingsCustomizeLibraryRuns()
        runs.answer = (0, Self.listing([Self.pr(43543, on: true), Self.night, Self.pr(43410, on: true)]), Data())
        let experiments = experiments(runs)
        var shown: [[String]] = []
        experiments.follow(runs) { shown.append($0.map(\.name)) }
        experiments.refresh()
        await until { !experiments.on.isEmpty }
        #expect(shown.last == ["pr-43543", "pr-43410"])
        runs.arguments = []
        runs.answer = (0, Self.listing([Self.pr(43543, on: false), Self.night, Self.pr(43410, on: false)]), Data())
        let refused = await experiments.turnOffAll()
        #expect(refused.isEmpty)
        #expect(Array(runs.arguments.prefix(2)) == [
            ["--json", "customize", "library", "off", "pr-43543"],
            ["--json", "customize", "library", "off", "pr-43410"],
        ])
        await until { experiments.on.isEmpty }
        #expect(shown.last == [])
    }

    @Test func theMarkIsHiddenWhileNoPullRequestIsOnAndShowsTheLineWhenOne() async throws {
        let runs = SettingsCustomizeLibraryRuns()
        runs.answer = (0, Self.listing([Self.night, Self.pr(43496, on: false)]), Data())
        let experiments = experiments(runs)
        let mark = experiments.makeMark(open: {})
        await until { !runs.arguments.isEmpty && experiments.isIdle }
        #expect(mark.isHidden, "nothing on: nothing shows")
        #expect(mark.line == nil)
        runs.answer = (0, Self.listing([Self.pr(43543, on: true)]), Data())
        experiments.refresh()
        await until { !mark.isHidden }
        #expect(mark.line == "Experiment on · #43543")
    }

    @Test func aRefusedTurnOffAnswersTheCLIsWords() async throws {
        let runs = SettingsCustomizeLibraryRuns()
        runs.answer = (0, Self.listing([Self.pr(43543, on: true)]), Data())
        let experiments = experiments(runs)
        experiments.refresh()
        await until { !experiments.on.isEmpty }
        runs.answer = (1, Data(), Data(#"{"code":"customize.library","message":"a preview is open"}"#.utf8))
        let refused = await experiments.turnOffAll()
        #expect(refused.map(\.name) == ["pr-43543"])
        #expect(refused.first?.message == "a preview is open")
    }
}
