import CmuxNextCloudUI
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Settings > Cloud > Compute: the platform's allotment view passed through, and one refusal for
/// every way it can be missing.
@MainActor @Suite struct CloudAllotmentPageTests {
    struct Off: Error {}

    @Test func passesThePlatformsViewThrough() async throws {
        let page = CloudAllotmentPage(available: { true }, get: { Data(#"{"allotment":{"month_micros":500000000},"names":{"user_1":"Ada"}}"#.utf8) })
        let view = try await page.read()
        #expect(view == .object(["allotment": .object(["month_micros": .number(500_000_000)]), "names": .object(["user_1": .string("Ada")])]))
    }

    @Test func offOrSignedOutAsksNothingAndRefuses() async {
        var asked = 0
        let page = CloudAllotmentPage(available: { false }, get: { asked += 1; return Data("{}".utf8) })
        await #expect(throws: PageError(code: "cmux.page.unavailable", message: "team compute is unavailable")) { _ = try await page.read() }
        #expect(asked == 0)
    }

    @Test func aFailedOrNullReadIsTheSameRefusal() async {
        for get: @MainActor () async throws -> Data in [{ throw Off() }, { Data("null".utf8) }] {
            let page = CloudAllotmentPage(available: { true }, get: get)
            await #expect(throws: PageError(code: "cmux.page.unavailable", message: "team compute is unavailable")) { _ = try await page.read() }
        }
    }
}
