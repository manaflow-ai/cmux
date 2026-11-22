import CmuxNextServer
import Foundation
import Testing
@testable import CmuxNextApp

/// Placing the user's Chief on a server that was just paired (G8), and the
/// panel's view of it (brains/DESIGN-cmux-lawrence.md).
@MainActor
@Suite struct CloudChiefPlacementTests {
    private final class Recorder {
        var calls: [(String, [String: Any])] = []
        var events: [ServerSourceEvent] = []
    }

    private static let chiefID = "agent_0123456789ABCDEFGHJKMNPQRS"
    private static let place = CloudChief.BrainPlace(host: "host_abcdefghij0123456789", install: "inst_abcdefghij0123456789")

    private static func chief(rev: Int = 3, place: CloudChief.BrainPlace? = nil, isDefault: Bool = true) -> [String: Any] {
        var value: [String: Any] = [
            "id": chiefID, "owner_user": "user_1", "display_name": "Chief", "is_default": isDefault, "brain": "cloud",
            "main_conversation": "conv_0123456789ABCDEFGHJKMNPQRS", "harness": NSNull(), "rev": rev,
        ]
        if let place { value["brain_place"] = ["host": place.host, "install": place.install] }
        return value
    }

    private static func ops(_ recorder: Recorder) -> [String] { recorder.calls.compactMap { $0.1["op"] as? String } }

    @Test func aChiefWithoutAPlaceReadsAsUnplaced() {
        #expect(CloudChief.parse(Self.chief())?.brainPlace == nil, "an older backend leaves brain_place out")
        var nulled = Self.chief()
        nulled["brain_place"] = NSNull()
        #expect(CloudChief.parse(nulled)?.brainPlace == nil)
        #expect(CloudChief.parse(Self.chief(place: Self.place))?.brainPlace == Self.place)
        let list = CloudChiefs.parseList(["chiefs": [Self.chief(isDefault: false), Self.chief(place: Self.place, isDefault: false)], "tombstones": []])
        #expect(CloudChiefs.placed(in: list)?.brainPlace == Self.place)
    }

    @Test func theDefaultChiefMovesToTheServer() async throws {
        let recorder = Recorder()
        let chief = try await CloudChiefs.place(Self.place, key: "k1") { path, body in
            recorder.calls.append((path, body))
            switch body["op"] as? String {
            case "chief.list": return ["value": ["chiefs": [Self.chief(rev: 3)], "tombstones": []]]
            default: return ["ok": true, "value": Self.chief(rev: 4, place: Self.place)]
            }
        }
        #expect(chief.brainPlace == Self.place)
        #expect(Self.ops(recorder) == ["chief.list", "chief.update"])
        let update = recorder.calls[1]
        #expect(update.0 == "v1/ops")
        #expect(update.1["origin"] as? String == "user")
        let params = update.1["params"] as? [String: Any]
        #expect(params?["chief"] as? String == Self.chiefID)
        #expect(params?["expected_rev"] as? Int == 3)
        #expect((params?["brain_place"] as? [String: Any])?["install"] as? String == Self.place.install)
    }

    @Test func aUserWithoutAChiefGetsOneOnTheServer() async throws {
        let recorder = Recorder()
        _ = try await CloudChiefs.place(Self.place, key: "k2") { path, body in
            recorder.calls.append((path, body))
            if body["op"] as? String == "chief.list" { return ["value": ["chiefs": [], "tombstones": []]] }
            return ["ok": true, "value": Self.chief(rev: 1, place: Self.place)]
        }
        #expect(Self.ops(recorder) == ["chief.list", "chief.create"])
        let params = recorder.calls[1].1["params"] as? [String: Any]
        #expect(params?["is_default"] as? Bool == true)
        #expect((params?["brain_place"] as? [String: Any])?["host"] as? String == Self.place.host)
    }

    @Test func aChiefAlreadyOnTheServerIsNotWrittenAgain() async throws {
        let recorder = Recorder()
        _ = try await CloudChiefs.place(Self.place, key: "k3") { path, body in
            recorder.calls.append((path, body))
            return ["value": ["chiefs": [Self.chief(place: Self.place)], "tombstones": []]]
        }
        #expect(Self.ops(recorder) == ["chief.list"])
    }

    @Test func aBackendThatIgnoresThePlaceIsAnError() async {
        await #expect(throws: (any Error).self) {
            _ = try await CloudChiefs.place(Self.place, key: "k4") { _, body in
                if body["op"] as? String == "chief.list" { return ["value": ["chiefs": [Self.chief()], "tombstones": []]] }
                return ["ok": true, "value": Self.chief(rev: 4)]
            }
        }
    }

    @Test func approvingAChiefBrainPlacesTheChiefAfterThePairing() async {
        let recorder = Recorder()
        let source = CloudPairingSource(
            inner: MockServerSource(scenario: .healthyMac),
            call: { path, body in
                recorder.calls.append((path, body))
                switch body["op"] as? String {
                case "server.pair.approve":
                    return ["ok": true, "value": ["host": Self.place.host, "team": "team_1", "user": "user_1", "install": Self.place.install]]
                case "chief.list": return ["value": ["chiefs": [Self.chief(rev: 3)], "tombstones": []]]
                case "chief.update": return ["ok": true, "value": Self.chief(rev: 4, place: Self.place)]
                default: return ["value": [:]]
                }
            },
            account: { "Ada" }
        )
        source.start { recorder.events.append($0) }
        source.send(ServerIntent(kind: .approveCode(code: "7KQ4M2XD", team: "team_1", name: "cmux-lawrence", placeChief: true), key: "k5"))
        var settled: String??
        for _ in 0..<400 where settled == nil {
            for case let .settled(key, reject) in recorder.events where key == "k5" { settled = .some(reject) }
            await Task.yield()
        }
        #expect(settled == .some(nil))
        let ops = Self.ops(recorder)
        #expect(ops.firstIndex(of: "server.pair.approve")! < ops.firstIndex(of: "chief.update")!)
    }

    @Test func aPlainApproveLeavesTheChiefAlone() async {
        let recorder = Recorder()
        let source = CloudPairingSource(
            inner: MockServerSource(scenario: .healthyMac),
            call: { path, body in
                recorder.calls.append((path, body))
                return ["ok": true, "value": ["host": Self.place.host, "team": "team_1", "user": "user_1", "install": Self.place.install]]
            },
            account: { "Ada" }
        )
        source.start { recorder.events.append($0) }
        source.send(ServerIntent(kind: .approveCode(code: "7KQ4M2XD", team: "team_1", name: "mini"), key: "k6"))
        for _ in 0..<200 { await Task.yield() }
        #expect(!Self.ops(recorder).contains("chief.update"))
        #expect(!Self.ops(recorder).contains("chief.create"))
    }

    @Test func aBrainSaysSoInItsPairingInfo() {
        var preview: [String: Any] = [
            "code": "7KQ4M2XD", "thumbprint": "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo", "country": NSNull(), "expires_at": 1,
            "info": ["name": "cmux-lawrence", "platform": "macos", "os_version": "26.5", "arch": "aarch64", "cmux_version": "0.1.0",
                     "capabilities": ["optchat-chief-brain"]],
        ]
        let team = ServerTeam(id: "team_1", name: "Ada")
        #expect(CloudPairingSource.candidate(from: preview, team: team)?.isChiefBrain == true)
        // A version string is never a role: only the explicit capability counts.
        preview["info"] = ["name": "mini", "platform": "macos", "os_version": "26.5", "arch": "aarch64", "cmux_version": "optchat-chief/0.1.0"]
        #expect(CloudPairingSource.candidate(from: preview, team: team)?.isChiefBrain == false)
        preview["info"] = ["name": "mini", "platform": "macos", "os_version": "26.5", "arch": "aarch64", "cmux_version": "0.9.0", "capabilities": ["postgres"]]
        #expect(CloudPairingSource.candidate(from: preview, team: team)?.isChiefBrain == false)
    }

    @Test func theChiefStateComesFromItsConversation() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let chief = CloudChief.parse(Self.chief(place: Self.place))!
        func message(_ author: String, _ secondsAgo: Double) -> [String: Any] {
            ["author": author, "created_at": CloudChiefStatus.format(now.addingTimeInterval(-secondsAgo))]
        }
        let ready = CloudChiefStatus.status(chief: chief, serverName: "cmux-lawrence",
                                            messages: [message("user_1", 300), message(Self.chiefID, 200)], now: now)
        #expect(ready.state == .ready)
        #expect(ready.serverName == "cmux-lawrence")
        #expect(ready.lastReply.map { Int(now.timeIntervalSince($0)) } == 200)
        let thinking = CloudChiefStatus.status(chief: chief, serverName: "s", messages: [message(Self.chiefID, 200), message("user_1", 30)], now: now)
        #expect(thinking.state == .thinking)
        let silent = CloudChiefStatus.status(chief: chief, serverName: "s", messages: [message(Self.chiefID, 900), message("user_1", 600)], now: now)
        #expect(silent.state == .notAnswering)
        let fresh = CloudChiefStatus.status(chief: chief, serverName: "s", messages: [], now: now)
        #expect(fresh.state == .ready)
        #expect(fresh.lastReply == nil)
    }

    /// The brain's read cursor tells a long turn from a silent server: a
    /// message the Chief has read is being worked on however long the turn
    /// runs (it read "not answering" after 120 s, cx-ebm.7 slice 0); one it
    /// has not read past the quiet limit is not answering.
    @Test func theChiefsReadCursorSeparatesALongTurnFromASilentServer() throws {
        let now = Date(timeIntervalSince1970: 1_790_985_600)
        let chief = try #require(CloudChief.parse(["id": Self.chiefID, "rev": 1, "main_conversation": "conv_m"]))
        func message(_ seq: Int, _ author: String, _ secondsAgo: Double) -> [String: Any] {
            ["seq": seq, "author": author, "created_at": CloudChiefStatus.format(now.addingTimeInterval(-secondsAgo))]
        }
        let messages = [message(1, Self.chiefID, 900), message(2, "user_1", 600)]
        let working = CloudChiefStatus.status(chief: chief, serverName: "s", messages: messages, chiefReadSeq: 2, now: now)
        #expect(working.state == .thinking, "read 10 minutes ago, the turn still runs")
        let unread = CloudChiefStatus.status(chief: chief, serverName: "s", messages: messages, chiefReadSeq: 1, now: now)
        #expect(unread.state == .notAnswering)
        let justArrived = CloudChiefStatus.status(chief: chief, serverName: "s",
                                                  messages: [message(1, Self.chiefID, 900), message(2, "user_1", 20)], chiefReadSeq: 1, now: now)
        #expect(justArrived.state == .thinking)
    }
}
