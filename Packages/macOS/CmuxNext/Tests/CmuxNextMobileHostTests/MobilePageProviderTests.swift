import CmuxNextMobileHost
import CmuxNextPages
import CmuxNextSettings
import Testing

/// Settings > Mobile's ops: only the person's gesture on the Settings page removes a phone.
@MainActor @Suite struct MobilePageProviderTests {
    @Test func removeNeedsTheSettingsPageAndAGesture() async throws {
        let provider = MobilePageProvider(host: IPhoneHostService())
        let params: JSONValue = ["id": "phone-1"]
        for context in [PageCallContext(page: "cmux.settings"), PageCallContext(page: "cmux.history", userGesture: true)] {
            await #expect(throws: PageError.self) { _ = try await provider.call("cmux.settings.mobile.remove_phone", params: params, context: context) }
        }
        let answer = try await provider.call("cmux.settings.mobile.remove_phone", params: params,
                                             context: PageCallContext(page: "cmux.settings", userGesture: true))
        #expect(answer == .object([:]))
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.settings.mobile.remove_phone", params: .object([:]),
                                        context: PageCallContext(page: "cmux.settings", userGesture: true))
        }
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.settings.mobile.other", params: params, context: PageCallContext(page: "cmux.settings", userGesture: true))
        }
    }

    @Test func allowAgainNeedsTheSettingsPageAndAGesture() async throws {
        let provider = MobilePageProvider(host: IPhoneHostService())
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.settings.mobile.allow_again", params: .object([:]), context: PageCallContext(page: "cmux.settings"))
        }
        let answer = try await provider.call("cmux.settings.mobile.allow_again", params: .object([:]),
                                             context: PageCallContext(page: "cmux.settings", userGesture: true))
        #expect(answer == .object([:]))
    }

    @Test func aHostWithNoAccountShowsOffWithNoPhones() {
        let json = IPhoneHostService().pageJSON
        #expect(json["allowed"] == .bool(false))
        #expect(json["phase"] == .string("off"))
        #expect(json["account"] == .null)
        #expect(json["phones"] == .array([]))
    }
}
