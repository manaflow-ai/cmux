@testable import CmuxNextCloudCredentials
import Foundation
import Testing

/// A Cloud start's agent is checked before its new machine is made (red 1 of the Cloud composer journey, 2026-11-10: a
/// start leased a machine, then Claude said "You've hit your weekly limit · resets Nov 14, 1pm (UTC)"). The test account
/// may never reach a limit, so the used-up path runs here on a recorded reply, through the app FFI's rule, with no network.
@MainActor struct CloudAgentCheckTests {
    /// 2026-11-11T04:00:00Z.
    nonisolated static let now: Int64 = 1_794_369_600
    /// 2026-11-14T13:00:00Z.
    nonisolated static let reset = "1794661200"
    static let weeklyWords = "Claude's weekly limit is used up until Nov 14, 1pm UTC. Pick Codex, or start after then."

    nonisolated final class Sent: @unchecked Sendable { var requests: [URLRequest] = [] }

    /// A check whose probe answers `status` with `headers`, whose login is `token`, at ``now``.
    func check(status: Int, headers: [String: String], token: Data? = Data("sk-ant-oat01-test".utf8), sent: Sent = Sent()) -> CloudAgentCheck {
        let check = CloudAgentCheck()
        check.now = { Self.now }
        check.cachedLogin = { _, _, _ in token }
        check.send = { request in
            sent.requests.append(request)
            await Task.yield() // a second start asks while this one is in flight
            let url = request.url ?? URL(fileURLWithPath: "/")
            return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) ?? HTTPURLResponse())
        }
        return check
    }

    static let weeklySpent = [
        "anthropic-ratelimit-unified-status": "rejected",
        "anthropic-ratelimit-unified-representative-claim": "seven_day",
        "anthropic-ratelimit-unified-7d-reset": reset,
        "request-id": "req_x",
    ]

    /// A fresh person, with `stored` as their kept login choice (cleared again by ``forget(_:)``).
    func person(stored: CloudHarnessLoginDecision.Choice? = nil) -> String {
        let user = "u-\(UUID().uuidString)"
        if let stored { CloudHarnessLoginChoices().save(stored, userID: user) }
        return user
    }

    func forget(_ user: String) { UserDefaults.standard.removeObject(forKey: "cmux.cloud.harnessLoginChoice." + user) }

    func refusal(_ check: CloudAgentCheck, harness: String? = "claude", model: String? = nil, login: CloudHarnessLoginAsk = .init(),
                 user: String, dogfood: Bool = true) async -> CloudAgentCheck.Refused? {
        await check.newMachineRefusal(harness: harness, model: model, login: login, userID: user, teamID: nil, otherTeams: [], dogfood: dogfood)
    }

    @Test func aUsedUpWeeklyLimitRefusesWithItsResetAndAsksOnce() async {
        let sent = Sent()
        let check = check(status: 429, headers: Self.weeklySpent, sent: sent)
        let user = person()
        // Two starts at once, then a third: one ask, and the answer stands until the reset.
        async let first = refusal(check, user: user)
        async let second = refusal(check, harness: nil, user: user)
        #expect(await [first, second] == [.limit(Self.weeklyWords), .limit(Self.weeklyWords)])
        #expect(await refusal(check, user: user) == .limit(Self.weeklyWords))
        #expect(sent.requests.count == 1)
        let request = sent.requests[0]
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat01-test")
        let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        #expect(body?["max_tokens"] as? Int == 1)
        #expect(body?["model"] as? String == CloudAgentCheck.probeModel)
    }

    /// A start's own model is the one asked, and a model's own weekly window stops only that model.
    @Test func theStartsModelIsAskedAndItsOwnWindowStopsOnlyIt() async {
        let opusSpent = ["anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-representative-claim": "seven_day_opus",
                         "anthropic-ratelimit-unified-reset": Self.reset]
        let sent = Sent()
        let check = check(status: 429, headers: opusSpent, sent: sent)
        let user = person()
        #expect(await refusal(check, model: "claude-opus-5-5", user: user)
            == .limit("Claude's weekly Opus limit is used up until Nov 14, 1pm UTC. Pick Codex, or start after then."))
        let body = try? JSONSerialization.jsonObject(with: sent.requests.first?.httpBody ?? Data()) as? [String: Any]
        #expect(body?["model"] as? String == "claude-opus-5-5")
        #expect(await refusal(check, model: "claude-sonnet-5-5", user: user) == nil)
        #expect(await refusal(check, user: user) == nil)
    }

    @Test func onlyAKnownUsedUpLimitOnALoginTheMachineGetsRefuses() async {
        let user = person()
        // An allowed answer, a login the provider rejected, no limit headers: the start goes on.
        for (status, headers) in [(200, ["anthropic-ratelimit-unified-status": "allowed"]), (401, [:]), (429, ["retry-after": "3"])] {
            #expect(await refusal(check(status: status, headers: headers), user: user) == nil)
        }
        let sent = Sent()
        // No cached login (the machine signs in on its own): nothing is asked.
        #expect(await refusal(check(status: 429, headers: Self.weeklySpent, token: nil, sent: sent), user: user) == nil)
        let spent = check(status: 429, headers: Self.weeklySpent, sent: sent)
        // Codex and `--login none`/`machine` carry no Claude login; nor does Release, whose remote switch is not read here.
        #expect(await refusal(spent, harness: "codex", user: user) == nil)
        #expect(await refusal(spent, login: .init(requested: CloudHarnessLoginDecision.Choice.none, byPerson: true), user: person()) == nil)
        #expect(await refusal(spent, login: .init(requested: .machine, byPerson: true, headless: true), user: person()) == nil)
        #expect(await refusal(spent, user: user, dogfood: false) == nil)
        // An agent's --login pass never overrides the person's kept none or machine: their machine gets no Claude login.
        for kept in [CloudHarnessLoginDecision.Choice.none, .machine] {
            let chose = person(stored: kept)
            #expect(await refusal(spent, login: .init(requested: .pass, byPerson: false, headless: true), user: chose)?.limitWords == nil)
            forget(chose)
        }
        #expect(sent.requests.isEmpty)
    }

    @Test func onlyTheLimitHeadersLeaveTheReply() {
        let url = URL(fileURLWithPath: "/")
        let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
                                       headerFields: ["Anthropic-Ratelimit-Unified-Status": "rejected", "request-id": "r", "set-cookie": "x"]) ?? HTTPURLResponse()
        #expect(CloudAgentCheck.probe(response) == .init(status: 429, headers: ["anthropic-ratelimit-unified-status": "rejected"]))
    }

    /// `cmux chat --on vm:new` may show no prompt: a new machine's login refusal comes before the machine.
    @Test func aHeadlessStartWithNoLoginChoiceIsRefusedBeforeTheMachine() async {
        let sent = Sent()
        let check = check(status: 200, headers: [:], sent: sent)
        let user = person()
        let headless = CloudHarnessLoginAsk(requested: nil, byPerson: false, headless: true)
        #expect(await refusal(check, harness: "codex", login: headless, user: user) == .login(.needsLoginChoice))
        #expect(await refusal(check, harness: "codex", login: .init(requested: .pass, headless: true), user: user) == .login(.needsLoginChoice))
        // The person's own --login pass is their choice: the start goes on (the broker gives Codex its login).
        let chose = person()
        #expect(await refusal(check, harness: "codex", login: .init(requested: .pass, byPerson: true, headless: true), user: chose) == nil)
        // A start that may ask (the composer) is never refused here; nor is Release.
        #expect(await refusal(check, harness: "codex", user: user) == nil)
        #expect(await refusal(check, harness: "codex", login: headless, user: user, dogfood: false) == nil)
        forget(user)
        forget(chose)
    }
}
