@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextHome
import CmuxNextPages
import CmuxNextSettings
import Testing

/// Settings > Chief > Voice input (Leo's list): the message box's mic, the Debug toggle
/// `home.voiceInput` itself. The row exists only where that tunable does (the store is active in
/// DEV and NIGHTLY); it reads and writes the tunable, so it starts on, as Leo set it.
@MainActor @Suite struct ChiefVoiceInputPageRouteTests {
    private static let settings = PageCallContext(page: "cmux.settings", userGesture: true)

    private static func activeStore() -> TunableStore {
        let store = TunableStore()
        store.register([HomeTunables.voiceInput.descriptor])
        store.activate(file: nil)
        return store
    }

    @Test func aBuildWithoutTheTunableHasNoRowAndRefusesTheWrite() async {
        let route = ChiefVoiceInputPageRoute(store: TunableStore())
        #expect(route.hostJSON == .null)
        await #expect(throws: PageError.self) {
            _ = try await route.call(ChiefVoiceInputPageRoute.prefix + "set", params: ["on": false], context: Self.settings)
        }
    }

    @Test func theRowShowsTheTunableOnByDefaultAndWritesIt() async throws {
        let store = Self.activeStore()
        let route = ChiefVoiceInputPageRoute(store: store)
        #expect(route.hostJSON == ["on": true])
        _ = try await route.call(ChiefVoiceInputPageRoute.prefix + "set", params: ["on": false], context: Self.settings)
        #expect(HomeTunables.voiceInput.value(in: store) == false)
        #expect(route.hostJSON == ["on": false])
        _ = try await route.call(ChiefVoiceInputPageRoute.prefix + "set", params: ["on": true], context: Self.settings)
        #expect(HomeTunables.voiceInput.value(in: store) == true)
    }

    @Test func onlyThePersonsClickOnSettingsWrites() async {
        let store = Self.activeStore()
        let route = ChiefVoiceInputPageRoute(store: store)
        for context in [PageCallContext(page: "cmux.settings"), PageCallContext(page: "cmux.history", userGesture: true)] {
            await #expect(throws: PageError.self) {
                _ = try await route.call(ChiefVoiceInputPageRoute.prefix + "set", params: ["on": false], context: context)
            }
        }
        await #expect(throws: PageError.self) {
            _ = try await route.call(ChiefVoiceInputPageRoute.prefix + "set", params: .object([:]), context: Self.settings)
        }
        #expect(HomeTunables.voiceInput.value(in: store) == true)
    }
}
