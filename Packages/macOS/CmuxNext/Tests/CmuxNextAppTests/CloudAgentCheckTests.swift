@testable import CmuxNextCloudCredentials
import Foundation
import Testing

/// A Cloud start's agent is checked before its lease (red 1 of the Cloud composer journey, 2026-11-10: a start leased
/// a machine, then Claude said "You've hit your weekly limit · resets Nov 14, 1pm (UTC)"). The test account may never
/// reach a limit, so the used-up path runs here on a recorded reply, through the app FFI's rule, with no network.
@MainActor struct CloudAgentCheckTests {
    /// 2026-11-11T04:00:00Z.
    static let now: Int64 = 1_794_369_600
    /// 2026-11-14T13:00:00Z.
    static let reset = "1794661200"

    final class Sent: @unchecked Sendable { var requests: [URLRequest] = [] }

    /// A check whose probe answers `status` with `headers`, whose login is `token`, at ``now``.
    func check(status: Int, headers: [String: String], token: Data? = Data("sk-ant-oat01-test".utf8), sent: Sent = Sent()) -> CloudAgentCheck {
        let check = CloudAgentCheck()
        check.now = { Self.now }
        check.cachedLogin = { _, _, _ in token }
        check.send = { request in
            sent.requests.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data(), response)
        }
        return check
    }

    static let weeklySpent = [
        "anthropic-ratelimit-unified-status": "rejected",
        "anthropic-ratelimit-unified-representative-claim": "seven_day",
        "anthropic-ratelimit-unified-7d-reset": reset,
        "request-id": "req_x",
    ]

    @Test func aUsedUpWeeklyLimitRefusesWithItsResetAndAsksOnce() async {
        let sent = Sent()
        let check = check(status: 429, headers: Self.weeklySpent, sent: sent)
        let user = "u-\(UUID().uuidString)"
        let message = "Claude's weekly limit is used up until Nov 14, 1pm UTC. Pick Codex, or start after then."
        #expect(await check.limitRefusal(harness: "claude", login: .init(), userID: user, teamID: nil, otherTeams: []) == message)
        // Until the reset, the next start is refused with no second ask.
        #expect(await check.limitRefusal(harness: nil, login: .init(), userID: user, teamID: nil, otherTeams: []) == message)
        #expect(sent.requests.count == 1)
        let request = sent.requests[0]
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat01-test")
        let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        #expect(body?["max_tokens"] as? Int == 1)
    }

    @Test func onlyAKnownUsedUpClaudeLimitRefuses() async {
        let user = "u-\(UUID().uuidString)"
        // An allowed answer, a login the provider rejected, no limit headers: the start goes on.
        for (status, headers) in [(200, ["anthropic-ratelimit-unified-status": "allowed"]), (401, [:]), (429, ["retry-after": "3"])] {
            #expect(await check(status: status, headers: headers).limitRefusal(harness: "claude", login: .init(), userID: user, teamID: nil, otherTeams: []) == nil)
        }
        // No cached login (the machine signs in on its own): nothing is asked, the start goes on.
        let sent = Sent()
        #expect(await check(status: 429, headers: Self.weeklySpent, token: nil, sent: sent).limitRefusal(harness: "claude", login: .init(), userID: user, teamID: nil, otherTeams: []) == nil)
        #expect(sent.requests.isEmpty)
        // Codex, `--login none` and `--login machine` never carry the Claude login: nothing is asked.
        let spent = check(status: 429, headers: Self.weeklySpent, sent: sent)
        #expect(await spent.limitRefusal(harness: "codex", login: .init(), userID: user, teamID: nil, otherTeams: []) == nil)
        #expect(await spent.limitRefusal(harness: "claude", login: .init(requested: CloudHarnessLoginDecision.Choice.none), userID: user, teamID: nil, otherTeams: []) == nil)
        #expect(await spent.limitRefusal(harness: "claude", login: .init(requested: .machine), userID: user, teamID: nil, otherTeams: []) == nil)
        #expect(await spent.limitRefusal(harness: "claude", login: .init(), userID: nil, teamID: nil, otherTeams: []) == nil)
        #expect(sent.requests.isEmpty)
    }

    @Test func onlyTheLimitHeadersLeaveTheReply() {
        let response = HTTPURLResponse(url: URL(string: "https://api.anthropic.com/v1/messages")!, statusCode: 429, httpVersion: nil,
                                       headerFields: ["Anthropic-Ratelimit-Unified-Status": "rejected", "request-id": "r", "set-cookie": "x"])!
        #expect(CloudAgentCheck.probe(response) == .init(status: 429, headers: ["anthropic-ratelimit-unified-status": "rejected"]))
    }

    /// `cmux chat --on vm:new` may show no prompt: a new machine's login refusal comes before the machine.
    @Test func aHeadlessCodexStartWithNoLoginChoiceIsRefusedBeforeTheMachine() async {
        let check = CloudAgentCheck()
        let user = "u-\(UUID().uuidString)"
        let headless = CloudHarnessLoginAsk(requested: nil, byPerson: false, headless: true)
        #expect(await check.loginRefusal(harness: "codex", login: headless, userID: user, teamID: nil, otherTeams: [], dogfood: true) == .needsLoginChoice)
        // The person's own --login pass is their choice: the start goes on and the broker gives the login.
        let chosen = CloudHarnessLoginAsk(requested: .pass, byPerson: false, headless: true)
        let person = CloudHarnessLoginAsk(requested: .pass, byPerson: true, headless: true)
        #expect(await check.loginRefusal(harness: "codex", login: chosen, userID: user, teamID: nil, otherTeams: [], dogfood: true) == .needsLoginChoice)
        #expect(await check.loginRefusal(harness: "codex", login: person, userID: user, teamID: nil, otherTeams: [], dogfood: true) == nil)
        // A start that may ask (the composer) is never refused here; nor is Release, whose remote switch is not read.
        #expect(await check.loginRefusal(harness: "codex", login: .init(), userID: user, teamID: nil, otherTeams: [], dogfood: true) == nil)
        #expect(await check.loginRefusal(harness: "codex", login: headless, userID: user, teamID: nil, otherTeams: [], dogfood: false) == nil)
        UserDefaults.standard.removeObject(forKey: "cmux.cloud.harnessLoginChoice." + user)
    }
}
