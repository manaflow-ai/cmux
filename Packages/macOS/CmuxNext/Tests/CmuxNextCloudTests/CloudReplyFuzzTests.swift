import CmuxFuzzSupport
@testable import CmuxNextCloud
import Foundation
import Testing

/// Seeded fuzz of what the Cloud side sends the app (plans/cmux-next/chrome-parity/p10-stability.md, task 180):
/// `/api/vm` replies as every response type, the API Worker's `{ok, value}` replies (owner routes and hands),
/// the user wire's hand frames, the link helpers' JSON lines, the app server's link events and connect
/// answers, install token claims and the move retries kept in defaults. Garbage, truncated and deeply nested
/// input. Chrome fuzzes the same kind of boundary where its browser reads a service's JSON
/// (services/data_decoder/public/cpp/json_sanitizer_fuzzer.cc, base/json/json_reader_fuzzer.cc).
///
/// The properties:
/// - no reply traps, whatever JSON type a field or the whole `value` has;
/// - a reply outside 2xx, or not `{ok: true, value}`, is `CloudAPIError.http` with its status; a 2xx reply that
///   is not the type is `CloudAPIError.decoding`;
/// - a hand frame names only ids the client accepts; a link line names a non-empty socket; a connect answer
///   gives the asked machine's socket or a `CloudLinkError`;
/// - a retry this version cannot read drops alone, and a retry written reads back.
///
/// It runs only with `CMUX_CLOUD_FUZZ=1`; agents run it on the fleet, CI does not (Lawrence 2026-10-23):
///
/// ```
/// CMUX_CLOUD_FUZZ=1 swift test --filter CloudReplyFuzzTests
/// CMUX_CLOUD_FUZZ=1 CMUX_FUZZ_DEADLINE=$(( $(date +%s) + 300 )) swift test --filter CloudReplyFuzzTests
/// ```
///
/// The runs are CmuxFuzzSupport `FuzzRun`s (p10-stability-016): `CMUX_FUZZ_SEED` and `CMUX_FUZZ_ITERATIONS`
/// replay a failure, and with `CMUX_FUZZ_ARTIFACTS` set a trap leaves its input behind.
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_CLOUD_FUZZ"] == "1",
        "set CMUX_CLOUD_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    )
)
struct CloudReplyFuzzTests {
    /// Two minutes past a long run's budget, so the limit stops a hang and never a long run.
    static let timeLimitMinutes: Int = {
        let budget = (try? FuzzEnvironment.current())?.longModeBudget(from: Date()) ?? 0
        return 2 + Int((budget / 60).rounded(.up))
    }()

    /// One input of the synchronous properties, its choices read from `data` (the libFuzzer entry,
    /// p10-stability-182). The connect answers await their resolver and the retries use defaults, so they
    /// are not part of it.
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        let branch = rng.below(5)
        let status = CloudReplyFuzzCases.statuses[rng.below(CloudReplyFuzzCases.statuses.count)]
        let bytes = rng.bytes(4_096)
        switch branch {
        case 0: try CloudReplyFuzzCases.apiReply(bytes, status: status)
        case 1: try CloudReplyFuzzCases.workerReply(bytes, status: status)
        case 2: try CloudReplyFuzzCases.handFrame(bytes)
        case 3: try CloudReplyFuzzCases.linkLine(bytes)
        default: try CloudReplyFuzzCases.installToken(String(decoding: bytes, as: UTF8.self), team: nil)
        }
    }

    @Test(.timeLimit(.minutes(CloudReplyFuzzTests.timeLimitMinutes)))
    func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("CloudReply.oneInput", seed: 0xC10D_0180_0001, iterations: 2_000)
        let tapes: [[UInt8]] = [[0], [1], [2], [3], [4], [1, 0, 40, 123, 34, 111, 107, 34, 58, 116, 114, 117, 101, 125]]
        try run.forEachInput(try run.corpus(seeds: tapes.map { Data($0) })) { try Self.oneInput($0) }
    }

    /// `/api/vm` replies damaged by JSON-token edits, as every response type, at several statuses.
    @Test(.timeLimit(.minutes(CloudReplyFuzzTests.timeLimitMinutes)))
    func apiRepliesDecodeOrThrowTyped() throws {
        let run = try FuzzRun("CloudReply.api", seed: 0xC10D_0180_0002, iterations: 4_000)
        let mutator = FuzzMutator(dictionary: CloudReplyFuzzCases.jsonTokens, maximumEdits: 6, maximumCount: 1 << 14)
        try run.forEachInput(try run.corpus(seeds: CloudReplyFuzzCases.apiSeeds), mutator: mutator) { data in
            for status in CloudReplyFuzzCases.statuses { try CloudReplyFuzzCases.apiReply(data, status: status) }
        }
    }

    /// Worker replies whose `value` is any JSON value, nested or not: never a trap, a typed error or the value.
    @Test(.timeLimit(.minutes(CloudReplyFuzzTests.timeLimitMinutes)))
    func workerRepliesOfAnyValueThrowTyped() throws {
        try FuzzRun("CloudReply.worker", seed: 0xC10D_0180_0003, iterations: 6_000).forEach { rng in
            let data = try CloudReplyFuzzCases.workerEnvelope(&rng).data()
            let status = rng.element(of: CloudReplyFuzzCases.statuses) ?? 200
            try CloudReplyFuzzCases.workerReply(data, status: status)
        }
    }

    /// Worker replies damaged by JSON-token edits.
    @Test(.timeLimit(.minutes(CloudReplyFuzzTests.timeLimitMinutes)))
    func damagedWorkerRepliesThrowTyped() throws {
        let run = try FuzzRun("CloudReply.workerBytes", seed: 0xC10D_0180_0004, iterations: 6_000)
        let mutator = FuzzMutator(dictionary: CloudReplyFuzzCases.jsonTokens, maximumEdits: 6, maximumCount: 1 << 14)
        try run.forEachInput(try run.corpus(seeds: CloudReplyFuzzCases.workerSeeds), mutator: mutator) { data in
            for status in CloudReplyFuzzCases.statuses { try CloudReplyFuzzCases.workerReply(data, status: status) }
        }
    }

    /// The user wire's frames and the link helpers' lines and events.
    @Test(.timeLimit(.minutes(CloudReplyFuzzTests.timeLimitMinutes)))
    func wireFramesAndLinkLinesNeverTrap() throws {
        let run = try FuzzRun("CloudReply.lines", seed: 0xC10D_0180_0005, iterations: 10_000)
        let mutator = FuzzMutator(dictionary: CloudReplyFuzzCases.jsonTokens, maximumEdits: 6, maximumCount: 1 << 13)
        try run.forEachInput(try run.corpus(seeds: CloudReplyFuzzCases.lineSeeds), mutator: mutator) { data in
            try CloudReplyFuzzCases.handFrame(data)
            try CloudReplyFuzzCases.linkLine(data)
        }
    }

    /// `cloud.machine.connect` answers through the real resolver: the asked machine's socket or a `CloudLinkError`.
    @Test(.timeLimit(.minutes(CloudReplyFuzzTests.timeLimitMinutes)))
    func connectAnswersGiveTheMachinesSocketOrALinkError() async throws {
        let run = try FuzzRun("CloudReply.connect", seed: 0xC10D_0180_0006, iterations: 2_000)
        let mutator = FuzzMutator(dictionary: CloudReplyFuzzCases.jsonTokens, maximumEdits: 4, maximumCount: 1 << 12)
        try await run.forEachInputAwaiting(try run.corpus(seeds: CloudReplyFuzzCases.connectSeeds), mutator: mutator) { data in
            try await CloudReplyFuzzCases.connectAnswer(data)
        }
    }

    /// Install tokens: any text, and JWTs whose payload holds any `team`.
    @Test(.timeLimit(.minutes(CloudReplyFuzzTests.timeLimitMinutes)))
    func installTokenTeamsReadOrAreNil() throws {
        try FuzzRun("CloudReply.token", seed: 0xC10D_0180_0007, iterations: 10_000).forEach { rng in
            let team: FuzzJSON = rng.oneIn(3) ? FuzzJSON.random(&rng, depth: 1) : .string(FuzzJSON.randomString(&rng, limit: 20))
            var claims: [String: FuzzJSON] = ["team": team, "sub": .string("u")]
            if rng.oneIn(4) { claims["team"] = nil }
            let payload = try FuzzJSON.object(claims).data().base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let token = "eyJhbGciOiJFUzI1NiJ9.\(payload).sig"
            var expected: String?
            if case .string(let text)? = claims["team"], !text.isEmpty { expected = text }
            try CloudReplyFuzzCases.installToken(token, team: expected)
            try CloudReplyFuzzCases.installToken(String(token.prefix(rng.below(token.count + 1))), team: nil)
        }
    }

    /// Move retries kept in defaults next to bytes this version cannot read.
    @MainActor
    @Test(.timeLimit(.minutes(CloudReplyFuzzTests.timeLimitMinutes)))
    func unreadableRetriesDropAlone() throws {
        let suite = "com.cmuxterm.next.cloud-fuzz.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let run = try FuzzRun("CloudReply.retries", seed: 0xC10D_0180_0008, iterations: 1_000)
        let mutator = FuzzMutator(dictionary: CloudReplyFuzzCases.jsonTokens, maximumEdits: 4, maximumCount: 1 << 12)
        try run.forEachInput(try run.corpus(seeds: CloudReplyFuzzCases.retrySeeds), mutator: mutator) { data in
            try CloudReplyFuzzCases.retries(data, in: defaults)
        }
    }
}

/// The fixed cases the fuzz found (p10-stability-180); they run on every `swift test`.
@Suite struct CloudReplyDecodeTrapTests {
    struct Started: Decodable, Equatable { var personInstance: String }

    /// A Worker reply whose `value` is a string, number, boolean or null is a decoding error. Before, the value
    /// went back through `JSONSerialization.data(withJSONObject:)`, which raises an Objective-C exception for a
    /// top-level value that is not an array or object, and the app ended.
    @Test(arguments: [#""x""#, "5", "true", "null", "[]"])
    func aWorkerValueOfAnotherTypeIsADecodingError(value: String) {
        let reply = Data(#"{"ok":true,"value":\#(value)}"#.utf8)
        do throws(CloudAPIError) {
            _ = try CloudOwnerAPIClient.reply(reply, status: 200, path: "/v1/x", as: Started.self)
            Issue.record("\(value) decoded as a keyed start")
        } catch {
            guard case .decoding = error else {
                Issue.record("\(value) gave \(error), not a decoding error")
                return
            }
        }
    }

    @Test(arguments: [#""x""#, "5", "true", "null", #"{"hand":"h"}"#])
    func aHandsValueThatIsNoListThrows(value: String) throws {
        let reply = Data(#"{"ok":true,"value":\#(value)}"#.utf8)
        let decoded = try HandsAPIClient.replyValue(reply, status: 200)
        #expect(throws: (any Error).self) { try HandsAPIClient.summaries(decoded) }
    }

    @Test func aWorkerValueOfTheTypeDecodes() throws {
        let reply = Data(#"{"ok":true,"value":{"personInstance":"p1"}}"#.utf8)
        #expect(try CloudOwnerAPIClient.reply(reply, status: 200, path: "/v1/x", as: Started.self) == Started(personInstance: "p1"))
        let hands = Data(#"{"ok":true,"value":[{"hand":"hand_abcdefghijklmnopqrst","name":"Mac","online":true}]}"#.utf8)
        #expect(try HandsAPIClient.summaries(try HandsAPIClient.replyValue(hands, status: 200)).map(\.name) == ["Mac"])
    }
}

/// The inputs and properties of ``CloudReplyFuzzTests``.
enum CloudReplyFuzzCases {
    static let statuses = [200, 201, 204, 299, 300, 401, 404, 409, 429, 500, 503]

    static let jsonTokens: [Data] = FuzzJSON.tokens + [
        #""ok""#, #""value""#, #""error""#, #""code""#, #""message""#, #""ui""#, #""vms""#, #""limits""#, #""id""#,
        #""status""#, #""capabilities""#, #""createdAt""#, #""size""#, #""entries""#, #""t""#, #""hand""#, #""event""#,
        #""socket""#, #""local_socket""#, #""connection""#, #""state""#, #""machine""#, #""generation""#,
        #""hand-approval-pending""#, #""hand-approval-settled""#, #""connection-snapshot""#, #""hub-ready""#,
        #""up""#, #""cmux/cloud""#, #""hand_abcdefghijklmnopqrst""#, #""0123456789abcdef0123456789abcdef0123""#,
    ].map { Data($0.utf8) }

    static let apiSeeds: [Data] = [
        #"{"vms":[{"id":"vm_a","provider":"freestyle","status":"running","displayName":"Box","createdAt":1.76e12,"address":{"ipv4":"10.0.0.2"},"size":{"name":"m","cpu":4,"memoryMb":8192,"storageMb":65536},"capabilities":{"snapshot":true,"exec":true,"attachTransports":["iroh"]},"pauseReason":"idle","idlePauseMinutes":30,"hourlyRateUsd":0.12,"runningSince":1.76e12},{"id":"vm_b","capabilities":["snapshot","agent_session"]}],"limits":{"maxActiveVms":3,"activeVmCount":1,"planId":"pro"}}"#,
        #"{"id":"vm_a","status":"weird"}"#,
        #"{"transport":"iroh","route":"r","session":"s","trustedCarrier":true,"expiresAtUnix":1.7e9,"invitation":{"uri":"u","invitationId":"i","expiresAtUnix":1.7e9}}"#,
        #"{"approved":true,"state":"approved","deviceFingerprint":"f"}"#,
        #"{"state":"running","cpus":2,"cpuPercent":12.5,"memoryTotalMb":1024,"memoryUsedMb":512}"#,
        #"{"snapshotId":"s1","name":"n"}"#, #"{"url":"https://p.cmux.dev"}"#,
        #"{"exitCode":0,"stdout":"ok","stderr":""}"#,
        #"{"entries":[{"name":"a","kind":"dir","size":12,"mode":493,"modifiedAt":1.7e12}]}"#,
        #"{"rules":[{"id":"r","port":22}]}"#, #"{"networks":[{"id":"n"}]}"#, #"{"domains":[{"domain":"a.test"}]}"#,
        #"{"verificationId":"v","domain":"a.test","state":"pending"}"#,
        #"[{"hand":"hand_abcdefghijklmnopqrst","name":"Mac","profile":"work","online":true,"level":"ask","pending_approvals":2}]"#,
        #"{"error":"vm_limit","message":"Too many","ui":{"message":"You have too many machines"}}"#, "", "{", "null",
    ].map { Data($0.utf8) }

    static let workerSeeds: [Data] = [
        #"{"ok":true,"value":{"personInstance":"p1","instance":"i","proof":"x"}}"#,
        #"{"ok":true,"value":[{"hand":"hand_abcdefghijklmnopqrst","name":"Mac"}]}"#,
        #"{"ok":false,"error":{"code":"forbidden","message":"No"}}"#, #"{"ok":true,"value":"x"}"#,
        #"{"ok":true,"value":null}"#, #"{"ok":1,"value":7}"#, #"{"ok":true}"#, "[]",
    ].map { Data($0.utf8) }

    static let lineSeeds: [Data] = [
        #"{"t":"welcome"}"#, #"{"t":"snapshot","hands":[]}"#,
        #"{"t":"hand-approval-pending","hand":"hand_abcdefghijklmnopqrst","id":"0123abcd-0123-abcd-0123-0123456789ab","at":1.76e12,"summary":{"action":"exec","argv":["ls",1,null,{"a":[]}]}}"#,
        #"{"t":"hand-approval-settled","hand":"hand_abcdefghijklmnopqrst","id":"0123abcd-0123-abcd-0123-0123456789ab","outcome":"allowed"}"#,
        #"{"event":"hub-ready","socket":"/tmp/cmux/hub.sock","routes":[]}"#,
        #"{"event":"connection-snapshot","local_socket":"/tmp/l.sock","connection":{"state":"connected"}}"#,
        #"{"app":"cmux/cloud","name":"cmux.cloud.link.changed","data":{"machine":"vm_a","state":"up","generation":3,"reason":"r"}}"#,
    ].map { Data($0.utf8) }

    static let connectSeeds: [Data] = [
        #"{"machine":"vm_a","carrier":"c","generation":4,"state":"up","socket":"/tmp/cmux-cloud/vm_a.sock"}"#,
        #"{"machine":"vm_b","state":"up","socket":"/tmp/x"}"#, #"{"machine":"vm_a","state":"down"}"#,
        #"{"machine":"vm_a","state":"up","socket":""}"#, #"{"machine":"vm_a","state":"up","generation":-1}"#,
    ].map { Data($0.utf8) }

    static let retrySeeds: [Data] = [
        #"{"t1":{"move":{"machineID":"vm_a"}},"t2":{"show":{"_0":{"session":"s","machineID":"vm_a","folder":"/w","key":"k"}}},"t3":{"future":{}}}"#,
        #"{"t1":{"askFirst":{"machineID":"vm_a"}},"t2":7}"#, "[]", "",
    ].map { Data($0.utf8) }

    /// A Worker reply: `{ok, value}` with any value, or an error body, or another shape.
    static func workerEnvelope(_ rng: inout FuzzRNG) -> FuzzJSON {
        var record = FuzzRecord()
        record.require("ok", .bool(!rng.oneIn(6)), &rng, odds: 8)
        switch rng.below(4) {
        case 0: record.fields["value"] = .object(["personInstance": rng.oneIn(4) ? FuzzJSON.random(&rng) : .string("p")])
        case 1: record.fields["value"] = FuzzJSON.random(&rng, depth: 3)
        case 2: record.fields["error"] = .object(["code": FuzzJSON.random(&rng, depth: 0), "message": .string("m")])
        default: break
        }
        record.noise(&rng)
        return rng.oneIn(10) ? FuzzJSON.random(&rng, depth: 2) : record.json
    }

    // MARK: Properties

    /// A `/api/vm` reply at `status`, as every response type.
    static func apiReply(_ data: Data, status: Int) throws {
        if let machine = try reply(CloudMachine.self, data, status: status) { try check(machine) }
        if let list = try reply(CloudMachineList.self, data, status: status) {
            for machine in list.vms { try check(machine) }
            _ = list.limits?.maxActiveVms
        }
        _ = try reply(CloudAttachEndpoint.self, data, status: status)
        _ = try reply(CloudEnrollmentApproval.self, data, status: status)
        _ = try reply(CloudMachineStats.self, data, status: status)
        _ = try reply(CloudSnapshot.self, data, status: status)
        _ = try reply(CloudPortLink.self, data, status: status)
        _ = try reply(CloudExecResult.self, data, status: status)
        _ = try reply(CloudSCPEndpoint.self, data, status: status)
        _ = try reply(CloudFileContents.self, data, status: status)
        _ = try reply(CloudFileStat.self, data, status: status)
        _ = try reply([CloudFileEntry].self, data, status: status)
        _ = try reply(CloudTunnelEnrollment.self, data, status: status)
        _ = try reply(CloudTunnelNetworkMutation.self, data, status: status)
        _ = try reply(CloudFirewallRule.self, data, status: status)
        _ = try reply([CloudNetwork].self, data, status: status)
        _ = try reply([CloudDomain].self, data, status: status)
        _ = try reply(CloudDomainPublication.self, data, status: status)
        _ = try reply(CloudPublication.self, data, status: status)
        _ = try reply(CloudPublicationVerification.self, data, status: status)
        _ = try reply(CloudMachineLimits.self, data, status: status)
        _ = try reply([HandSummary].self, data, status: status)
        // An answer read for its status alone (start, stop, delete) never fails on its body.
        let ignored = try reply(CloudAPIClient.Ignored.self, data, status: status)
        try FuzzRun.check((ignored != nil) == (200..<300).contains(status), "an ignored body at \(status) was \(ignored == nil ? "refused" : "taken")")
    }

    /// `data` as a `T` through CloudAPIClient's reply path, or nil after checking the error it gave.
    static func reply<T: Decodable>(_ type: T.Type, _ data: Data, status: Int) throws -> T? {
        do throws(CloudAPIError) {
            return try CloudAPIClient.reply(data, status: status, headerCode: nil, path: "/api/vm", as: T.self)
        } catch {
            try expected(error, status: status, envelopeOK: (200..<300).contains(status))
            return nil
        }
    }

    /// `error` is the one a reply at `status` may give: the HTTP error with its status when the reply is not a
    /// value, else a decoding error.
    static func expected(_ error: CloudAPIError, status: Int, envelopeOK: Bool) throws {
        switch error {
        case .decoding: try FuzzRun.check(envelopeOK, "a reply at \(status) that is no value gave a decoding error")
        case .http(let code, _, _): try FuzzRun.check(!envelopeOK && code == status, "a value reply at \(status) gave HTTP \(code)")
        default: try FuzzRun.check(false, "a reply at \(status) gave \(error)")
        }
    }

    /// The acpmux answers the owner client reads (`keyed-start`, `person-holds`).
    struct Started: Decodable { var personInstance: String }
    struct Holds: Decodable { var instance: String; var proof: String }

    /// `data` through the owner client as a `T`: the value, or the error a reply at `status` may give.
    static func ownerReply<T: Decodable>(_ type: T.Type, _ data: Data, status: Int, envelopeOK: Bool) throws {
        do throws(CloudAPIError) {
            _ = try CloudOwnerAPIClient.reply(data, status: status, path: "/v1/cloud", as: T.self)
        } catch {
            try expected(error, status: status, envelopeOK: envelopeOK)
            return
        }
        try FuzzRun.check(envelopeOK, "the owner client took a reply at \(status) that is no value")
    }

    static func check(_ machine: CloudMachine) throws {
        try FuzzRun.check(!machine.title.isEmpty || machine.id.isEmpty, "machine \(machine.id) has no title")
        _ = (machine.capabilities.supportedOperations, machine.allows(.exec), machine.status.isLive, machine.createdAt, machine.runningSince)
    }

    /// A Worker reply through the owner client and the hands client.
    static func workerReply(_ data: Data, status: Int) throws {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let envelopeOK = (200..<300).contains(status) && object?["ok"] as? Bool == true && object?["value"] != nil
        try ownerReply(Started.self, data, status: status, envelopeOK: envelopeOK)
        try ownerReply(Holds.self, data, status: status, envelopeOK: envelopeOK)
        try ownerReply([String: Int].self, data, status: status, envelopeOK: envelopeOK)
        let value: Any
        do throws(CloudAPIError) {
            value = try HandsAPIClient.replyValue(data, status: status)
        } catch {
            try expected(error, status: status, envelopeOK: envelopeOK)
            return
        }
        try FuzzRun.check(envelopeOK, "the hands client took a reply at \(status) that is no value")
        _ = try? HandsAPIClient.summaries(value)
        let rows = value as? [[String: Any]] ?? []
        for approval in rows.compactMap({ HandApproval($0, hand: "hand_abcdefghijklmnopqrst") }) {
            try FuzzRun.check(HandIDs.isHand(approval.hand) && HandIDs.isApproval(approval.id), "an approval with ids the client refuses")
        }
    }

    /// A user wire frame: only ids the client accepts, a summary of at most 300 characters.
    static func handFrame(_ data: Data) throws {
        switch HandApprovalWire.Frame.decode(data) {
        case .event(.pending(let approval)):
            try FuzzRun.check(HandIDs.isHand(approval.hand) && HandIDs.isApproval(approval.id), "a pending approval with ids the client refuses")
            try FuzzRun.check(approval.summary.count <= 300, "a summary of \(approval.summary.count) characters")
        case .event(.settled(let hand, let id, _)):
            try FuzzRun.check(HandIDs.isHand(hand) && HandIDs.isApproval(id), "a settled approval with ids the client refuses")
        case .event(.connected), .welcome, .snapshot, .ignored:
            break
        }
    }

    /// A link helper's line or an app server event.
    static func linkLine(_ data: Data) throws {
        let line = String(decoding: data, as: UTF8.self)
        switch CloudLinkEvent.parse(line) {
        case .hubReady(let socket), .connected(let socket):
            try FuzzRun.check(!socket.isEmpty, "a link line names an empty socket")
        case .other:
            break
        }
        _ = CloudLinkEvent.linkConnected(line)
        if let change = CloudLinkChange.parse(appServerEvent: data) {
            try FuzzRun.check(!change.key.machine.isEmpty, "a link change for no machine")
        }
    }

    /// A connect answer through ``CloudConnectOpResolver``: the asked machine's socket, or a `CloudLinkError`.
    static func connectAnswer(_ data: Data) async throws {
        let failure = data.first.map { $0 % 4 == 0 } ?? false
        let code = ["cmux.cloud.link_revoked", "cmux.cloud.link_down", "cmux.cloud.link_unavailable", "other"][Int(data.last ?? 0) % 4]
        let resolver = CloudConnectOpResolver(run: { _, _, _, _ in
            if failure { throw CloudAppOpError(code: code, message: String(decoding: data, as: UTF8.self)) }
            return data
        }, check: { _ in })
        let key = CloudLinkKey(machine: "vm_a")
        do {
            let socket = try await resolver.open(key, intent: "fuzz", origin: .script)
            try FuzzRun.check(!failure && socket.key == key && !socket.path.isEmpty, "a connect gave socket \(socket.path) for \(socket.key)")
        } catch is CloudLinkError {
        }
    }

    /// The `team` claim of an install token: `team` when the payload names one, never a trap.
    static func installToken(_ token: String, team: String?) throws {
        let read = MacInstallIdentity.team(ofToken: token)
        if let team { try FuzzRun.check(read == team, "token team \(team) read as \(String(describing: read))") }
        try FuzzRun.check(read.map { !$0.isEmpty } ?? true, "an empty team was read")
    }

    /// Retries in defaults beside `data` (any bytes as the stored value): reading never traps, and a retry
    /// written reads back with the others it could read.
    @MainActor
    static func retries(_ data: Data, in defaults: UserDefaults) throws {
        let retries = CloudMoveRetries(key: "moves")
        retries.defaults = { defaults }
        defaults.set(data, forKey: "moves")
        let before = Dictionary(uniqueKeysWithValues: retries.tabs.compactMap { tab in retries[tab].map { (tab, $0) } })
        let written = CloudMoveRetries.Retry.askFirst(machineID: "vm_fuzz")
        retries["fuzz-tab"] = written
        try FuzzRun.check(retries["fuzz-tab"] == written, "a written retry does not read back")
        for (tab, retry) in before where tab != "fuzz-tab" {
            try FuzzRun.check(retries[tab] == retry, "writing a retry lost the one of tab \(tab)")
        }
        defaults.removeObject(forKey: "moves")
    }
}
