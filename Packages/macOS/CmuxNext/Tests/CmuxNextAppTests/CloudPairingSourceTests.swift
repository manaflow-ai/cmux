import CmuxNextServer
import Foundation
import Testing
@testable import CmuxNextApp

/// "Add Server…" goes to the API Worker: preview by code, approve with the
/// intent's key and origin user (plans/cmux-next/server.md 6.2).
@MainActor
@Suite struct CloudPairingSourceTests {
    private final class Recorder {
        var calls: [(String, [String: Any])] = []
        var events: [ServerSourceEvent] = []
    }

    /// A Worker team id (the token's personal team), not a Stack team id.
    private static let workerTeam = "team_0123456789abcdefghij"
    private static let team = ServerTeam(id: workerTeam, name: "Ada")
    private static let preview: [String: Any] = [
        "code": "7KQ4M2XD",
        "info": ["name": "Mac mini", "platform": "macos", "os_version": "26.5", "arch": "aarch64", "cmux_version": "0.9.0"],
        "public_jwk": [:],
        "thumbprint": "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
        "country": "US",
        "expires_at": 1,
    ]

    private func source(_ recorder: Recorder, account: String? = "Ada",
                        reply: @escaping ([String: Any]) throws -> [String: Any]) -> CloudPairingSource {
        let source = CloudPairingSource(
            inner: MockServerSource(scenario: .healthyMac),
            call: { path, body in
                recorder.calls.append((path, body))
                if body["op"] as? String == "team.policy.get" { return ["value": ["team": Self.workerTeam]] }
                return try reply(body)
            },
            account: { account }
        )
        source.start { recorder.events.append($0) }
        return source
    }

    private func settled(_ recorder: Recorder, _ key: String) async -> String?? {
        for _ in 0..<200 {
            for case let .settled(k, reject) in recorder.events where k == key { return .some(reject) }
            await Task.yield()
        }
        return nil
    }

    @Test func previewBuildsTheCandidateWithFingerprintWords() {
        let candidate = CloudPairingSource.candidate(from: Self.preview, team: Self.team)
        #expect(candidate?.name == "Mac mini")
        #expect(candidate?.os == "macos 26.5")
        #expect(candidate?.version == "0.9.0")
        #expect(candidate?.region == "US")
        #expect(candidate?.words == ["capable", "various", "jewel", "dress"])
        #expect(candidate?.teams == [Self.team])
        var bad = Self.preview
        bad["thumbprint"] = "AAEC"
        #expect(CloudPairingSource.candidate(from: bad, team: Self.team) == nil)
    }

    @Test func lookupReadsPreviewWithTheNormalizedCode() async {
        let recorder = Recorder()
        let source = source(recorder) { _ in ["value": Self.preview] }
        let intent = ServerIntent(kind: .lookupCode("7kq4-m2xd"), key: "k1")
        source.send(intent)
        #expect(await settled(recorder, "k1") == .some(nil))
        let preview = recorder.calls.first { $0.1["op"] as? String == "server.pair.preview" }
        #expect(preview?.0 == "v1/read")
        #expect((preview?.1["params"] as? [String: Any])?["code"] as? String == "7KQ4M2XD")
        // The candidate offers the Worker's team, never the app's Stack team id.
        let candidates = recorder.events.compactMap { if case let .candidate(c) = $0 { c } else { nil } }
        #expect(candidates.first?.teams.map(\.id) == [Self.workerTeam])
    }

    @Test func approveSendsOriginUserAndTheIntentKey() async {
        let recorder = Recorder()
        let source = source(recorder) { _ in ["ok": true, "value": ["host": "host_1", "team": Self.workerTeam]] }
        source.send(ServerIntent(kind: .approveCode(code: "7KQ4-M2XD", team: Self.workerTeam, name: "Mac mini"), key: "k2"))
        #expect(await settled(recorder, "k2") == .some(nil))
        let body = recorder.calls.first?.1
        #expect(recorder.calls.first?.0 == "v1/ops")
        #expect(body?["op"] as? String == "server.pair.approve")
        #expect(body?["origin"] as? String == "user")
        #expect(body?["idempotency_key"] as? String == "k2")
        let params = body?["params"] as? [String: Any]
        #expect(params?["code"] as? String == "7KQ4M2XD")
        #expect(params?["team"] as? String == Self.workerTeam)
    }

    /// A Worker error reply (`{_tag, code, message}`) or a reply without the
    /// enrolled host is a reject, never a success.
    @Test func approveWithoutAHostIsRefused() async {
        let recorder = Recorder()
        let tagged = source(recorder) { _ in ["_tag": "Forbidden", "code": "auth.forbidden", "message": "pairing needs a signed-in user"] }
        tagged.send(ServerIntent(kind: .approveCode(code: "7KQ4M2XD", team: Self.workerTeam, name: "x"), key: "k5"))
        #expect(await settled(recorder, "k5")??.contains("pairing needs a signed-in user") == true)
        let empty = source(recorder) { _ in ["ok": true, "value": [:]] }
        empty.send(ServerIntent(kind: .approveCode(code: "7KQ4M2XD", team: Self.workerTeam, name: "x"), key: "k6"))
        let reject = await settled(recorder, "k6")
        #expect(reject != nil && reject! != nil)
    }

    /// A user who only signed in on a Mac has no personal team yet: the
    /// first team read is forbidden, `user.ensure` runs once, the read repeats.
    @Test func aNewUserGetsAPersonalTeamFirst() async {
        let recorder = Recorder()
        var ensured = false
        let source = CloudPairingSource(
            inner: MockServerSource(scenario: .healthyMac),
            call: { path, body in
                recorder.calls.append((path, body))
                switch body["op"] as? String {
                case "team.policy.get" where !ensured:
                    return ["_tag": "Forbidden", "code": "auth.forbidden", "message": "not a member of this team"]
                case "team.policy.get": return ["value": ["team": Self.workerTeam]]
                case "user.ensure":
                    ensured = true
                    return ["ok": true, "value": [:]]
                default: return ["value": Self.preview]
                }
            },
            account: { "Ada" }
        )
        source.start { recorder.events.append($0) }
        source.send(ServerIntent(kind: .lookupCode("7KQ4M2XD"), key: "k7"))
        #expect(await settled(recorder, "k7") == .some(nil))
        let ops = recorder.calls.compactMap { $0.1["op"] as? String }
        #expect(ops == ["team.policy.get", "user.ensure", "team.policy.get", "server.pair.preview"])
        #expect(recorder.calls[1].1["origin"] as? String == "user")
    }

    @Test func signedOutAndOwnerRefusalsAreRejects() async {
        let recorder = Recorder()
        let signedOut = source(recorder, account: nil) { _ in [:] }
        signedOut.send(ServerIntent(kind: .lookupCode("7KQ4M2XD"), key: "k3"))
        let reject = await settled(recorder, "k3")
        #expect(reject != nil && reject! != nil)
        #expect(recorder.calls.isEmpty)

        let refused = source(recorder) { _ in throw FeedServiceError.owner(code: "auth.forbidden", message: "not allowed") }
        refused.send(ServerIntent(kind: .approveCode(code: "7KQ4M2XD", team: Self.workerTeam, name: "x"), key: "k4"))
        let owner = await settled(recorder, "k4")
        #expect(owner??.contains("not allowed") == true)
    }
}
