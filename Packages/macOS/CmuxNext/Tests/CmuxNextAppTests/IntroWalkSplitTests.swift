import CmuxNextActions
import CmuxNextPages
@testable import CmuxNextSettings
@testable import CmuxNextOnboarding
import Foundation
import Testing
@testable import CmuxNextApp

/// Make cmux Yours as a split (cmux-window-rules walk_split.rs): the window reads this install's
/// bundle when the walk shows and logs one start and one end per walk against it (Continue:
/// completed; Skip, close, quit: skipped) with the screen the page reported; the app's log keeps the
/// install key across launches and writes the Rust records, one JSON line each.
@MainActor @Suite(.serialized) struct IntroWalkSplitTests {
    @MainActor final class Split: IntroWalkSplitSource {
        var bundleID: String? = "wb1-000000"
        var records: [(bundle: String, ending: IntroWalkEnding, screen: Int)] = []
        func bundle() -> String? { bundleID }
        func record(bundle: String, ending: IntroWalkEnding, screen: Int) { records.append((bundle, ending, screen)) }
    }

    private func clicked(_ event: TimeInterval) -> PageCallContext {
        PageCallContext(page: "cmux.onboarding", userGesture: true, gestureEvent: event)
    }

    private func model(_ split: Split, step: OnboardingModel.Step = .makeItYours) -> OnboardingModel {
        let services = MockOnboardingServices()
        services.introWalkSplit = split
        return OnboardingModel(services: services, step: step, choices: nil)
    }

    @Test func continueLogsStartedThenCompletedWithTheScreen() async throws {
        let split = Split()
        let model = model(split)
        let page = OnboardingPageProvider(model: model)
        model.stepDidAppear()
        model.stepDidAppear() // shown again in the same window: still one start
        _ = try await page.call("cmux.onboarding.next", params: ["screen": 4], context: clicked(10))
        model.leave()
        #expect(split.records.map(\.ending) == [.started, .completed])
        #expect(split.records.map(\.bundle) == ["wb1-000000", "wb1-000000"])
        #expect(split.records.last?.screen == 4)
        #expect(model.walkBundle == "wb1-000000")
    }

    @Test func skipAndCloseLogSkipped() async throws {
        let skipped = Split()
        let first = model(skipped)
        first.stepDidAppear()
        _ = try await OnboardingPageProvider(model: first).call("cmux.onboarding.skip", params: ["screen": 1], context: clicked(20))
        #expect(skipped.records.map(\.ending) == [.started, .skipped])
        #expect(skipped.records.last?.screen == 1)

        let closed = Split()
        let second = model(closed)
        second.stepDidAppear()
        second.leave()
        #expect(closed.records.map(\.ending) == [.started, .skipped])
    }

    @Test func noBundleOrAnotherStepLogsNothing() {
        let none = Split()
        none.bundleID = nil
        let unanswered = model(none)
        unanswered.stepDidAppear()
        unanswered.finish(completed: true)
        #expect(none.records.isEmpty)

        let agents = Split()
        let other = model(agents, step: .agents)
        other.stepDidAppear()
        other.finish(completed: true)
        #expect(agents.records.isEmpty)
    }

    @Test func theAppLogKeepsItsKeyAndWritesTheRustRecords() throws {
        let suite = "IntroWalkSplitTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("intro-walk/outcomes.jsonl")

        let log = IntroWalkSplitLog(defaults: defaults, file: file)
        let key = log.installKey
        #expect(IntroWalkSplitLog(defaults: defaults, file: file).installKey == key, "the key survives a relaunch")
        // Every slot ships with its split off: every install sees today's walk.
        let bundle = try #require(log.bundle())
        #expect(bundle == "wb1-000000")
        log.record(bundle: bundle, ending: .started, screen: 0)
        log.record(bundle: bundle, ending: .completed, screen: 3)
        #expect(log.records() == [
            .init(version: 1, bundle: bundle, ending: .started, screen: 0),
            .init(version: 1, bundle: bundle, ending: .completed, screen: 3),
        ])
    }
}
