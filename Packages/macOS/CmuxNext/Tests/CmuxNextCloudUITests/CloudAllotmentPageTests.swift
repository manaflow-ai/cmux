import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Settings > Cloud > Compute: the platform's allotment view passed through, one refusal for every
/// way it can be missing, and the team's hold set passed through with the server's refusal kept.
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
        await expectRefusal(CloudAllotmentPage(available: { true }, get: { throw Off() }))
        await expectRefusal(CloudAllotmentPage(available: { true }, get: { Data("null".utf8) }))
    }

    @Test func aSetPassesTheParamsThroughAndItsAnswerBack() async throws {
        var sent: [JSONValue] = []
        let page = CloudAllotmentPage(available: { true }, get: { Data("{}".utf8) }, set: { args in
            sent.append(try JSONValue.parse(args))
            return Data(#"{"allotment":{"person_hold_seconds":900}}"#.utf8)
        })
        let answer = try await page.write(.object(["person_hold_seconds": .number(900)]))
        #expect(sent == [.object(["person_hold_seconds": .number(900)])])
        #expect(answer == .object(["allotment": .object(["person_hold_seconds": .number(900)])]))
    }

    @Test func aSetOffSignedOutOrUnservedAsksNothingAndRefuses() async {
        var asked = 0
        let off = CloudAllotmentPage(available: { false }, get: { Data("{}".utf8) }, set: { _ in asked += 1; return Data("{}".utf8) })
        await #expect(throws: PageError(code: "cmux.page.unavailable", message: "team compute is unavailable")) { _ = try await off.write(.object([:])) }
        #expect(asked == 0)
        let readOnly = CloudAllotmentPage(available: { true }, get: { Data("{}".utf8) })
        await #expect(throws: PageError(code: "cmux.page.unavailable", message: "team compute is unavailable")) { _ = try await readOnly.write(.object([:])) }
    }

    @Test func aRefusedSetKeepsTheServersSentence() async {
        let page = CloudAllotmentPage(available: { true }, get: { Data("{}".utf8) }, set: { _ in
            throw CloudAppOpFailure(code: "cmux.cloud.forbidden", message: "Only a team admin can change this.")
        })
        await #expect(throws: PageError(code: CloudAllotmentPage.refusedCode, message: "Only a team admin can change this.",
                                        details: .object(["code": .string("cmux.cloud.forbidden")]))) {
            _ = try await page.write(.object(["person_hold_seconds": .number(300)]))
        }
    }

    private func expectRefusal(_ page: CloudAllotmentPage) async {
        await #expect(throws: PageError(code: "cmux.page.unavailable", message: "team compute is unavailable")) { _ = try await page.read() }
    }
}
