import AppKit
@testable import CmuxNextOnboarding
import CmuxNextPages
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// The Set Up cmux card's Text Size and Density row (David Beyer, Nov 20: he could not find a sidebar font size):
/// the card shows the app's text size and density, and the person's pick writes `appearance.metrics.chromeFontSize`
/// or `appearance.density` through the settings writer, on their own click only, and only values the schema takes.
@MainActor @Suite(.serialized) struct SetupCardTextSizeTests {
    @MainActor final class Writes {
        var items: [(key: String, value: JSONValue?)] = []
    }

    func provider(writes: Writes, textSize: Double? = nil) throws -> SetupCardPageProvider {
        let suite = "cmux-setup-look-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let look = SetupCardLook(
            current: { SetupCardLook.Current(textSize: textSize, density: "cozy", body: 14) },
            write: { path, value in writes.items.append((path.joined(separator: "."), value)) })
        return SetupCardPageProvider(setup: FirstRunSetup(defaults: defaults), agents: nil, environment: SetupCardEnvironment(
            account: { (false, nil) }, signInAccount: {}, cliState: { "missing" }, installCLI: { _ in }, openAgents: {},
            look: look))
    }

    func click(_ at: TimeInterval) -> PageCallContext {
        PageCallContext(page: PageDescriptor.setupCard.id, userGesture: true, gestureEvent: at)
    }

    @Test func theCardShowsTheTextSizeAndDensityTheAppDraws() throws {
        let unset = try provider(writes: Writes())
        defer { unset.stop() }
        #expect(unset.state["look"] == ["textSize": .null, "density": "cozy", "body": 14])
        let set = try provider(writes: Writes(), textSize: 16)
        defer { set.stop() }
        #expect(set.state["look"]?["textSize"] == 16)
    }

    @Test func aPickWritesTheSettingThroughTheWriter() async throws {
        let writes = Writes()
        let provider = try provider(writes: writes)
        defer { provider.stop() }
        _ = try await provider.call("cmux.setup.run", params: ["action": ["kind": "setTextSize", "points": 16]], context: click(1))
        _ = try await provider.call("cmux.setup.run", params: ["action": ["kind": "setDensity", "id": "comfortable"]], context: click(2))
        _ = try await provider.call("cmux.setup.run", params: ["action": ["kind": "setTextSize", "points": .null]], context: click(3))
        await until { writes.items.count == 3 }
        #expect(writes.items.map(\.key) == ["appearance.metrics.chromeFontSize", "appearance.density", "appearance.metrics.chromeFontSize"])
        #expect(writes.items.map(\.value) == [.number(16), .string("comfortable"), nil])
    }

    @Test func valuesTheSchemaRefusesAndPagePushesWriteNothing() async throws {
        let writes = Writes()
        let provider = try provider(writes: writes)
        defer { provider.stop() }
        await #expect(throws: PageError.self) {
            try await provider.call("cmux.setup.run", params: ["action": ["kind": "setTextSize", "points": 40]], context: click(1))
        }
        await #expect(throws: PageError.self) {
            try await provider.call("cmux.setup.run", params: ["action": ["kind": "setDensity", "id": "huge"]], context: click(2))
        }
        // No click or key: the page cannot change the look on its own.
        await #expect(throws: PageError.self) {
            try await provider.call("cmux.setup.run", params: ["action": ["kind": "setTextSize", "points": 15]],
                                    context: PageCallContext(page: PageDescriptor.setupCard.id, userGesture: false, gestureEvent: nil))
        }
        #expect(writes.items.isEmpty)
    }

    private func until(_ done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        // test-only: waits for the provider's async settings write, bounded by the deadline
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
