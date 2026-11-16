@testable import CmuxNextServer
import CmuxNextSettings
import Foundation
import Testing

/// Settings > Devices' "Control from this Mac" (contract: signed remote Control/Screen consent grants):
/// one switch per machine the person owns, read when drawn (no timer), signed with this Mac's key only for
/// the machine the row names, both surfaces at once, and the target's one-time ask shown with its words.
@MainActor @Suite(.serialized) struct RemoteControlConsentTests {
    @MainActor final class Fake {
        var calls: [(method: String, params: [String: Any])] = []
        var signs: [String] = []
        /// What `_acpmux/consent_remote_status` answers.
        var status: [String: Any] = Fake.answer(control: false)
        /// What `_acpmux/consent_remote_set` answers.
        var setAnswer: [String: Any] = ["ok": true]
        /// What `_acpmux/machine_consent_get` answers (this Mac's record).
        var record: [String: Any] = ["consent": [:] as [String: Any], "account": "user_abc", "accountPolicy": NSNull()]
        /// What `_acpmux/consent_account_set` and `_acpmux/consent_trust_refresh` answer.
        var accountAnswer: [String: Any] = ["ok": true, "applied": [] as [Any]]
        var hasKey = true
        var recordReads = 0
        let now = Date(timeIntervalSince1970: 1_794_781_800)

        static func answer(machineId: String = "m_1", nodeKey: String = "Tk9ERQ==", account: String = "user_abc", control: Bool,
                           pinned: Bool? = true, log: [[String: Any]] = []) -> [String: Any] {
            var answer: [String: Any] = ["ok": true, "machineId": machineId, "nodeKey": nodeKey, "account": account, "host": "mini-7",
                                         "control": control, "screen": control, "grantLog": log,
                                         "self": ["account": "user_abc", "grantor": "mac-0011223344556677", "words": ["amber", "birch", "cedar", "delta"]]]
            answer["grantor"] = pinned.map { ["pinned": $0] as [String: Any] } ?? NSNull()
            return answer
        }

        func services() -> RemoteControlConsentServices {
            RemoteControlConsentServices(
                call: { [self] method, params in
                    calls.append((method, params))
                    switch method {
                    case "_acpmux/consent_remote_status": return .success(status)
                    case "_acpmux/consent_remote_set": return .success(setAnswer)
                    case "_acpmux/machine_consent_get": return .success(record)
                    case "_acpmux/consent_account_set", "_acpmux/consent_trust_refresh": return .success(accountAnswer)
                    default: return .failure(RemoteControlCallError("unknown"))
                    }
                },
                sign: { [self] account, machineId, nodeKey, on, name in
                    let change = on.map { $0 ? "on" : "off" } ?? "default"
                    signs.append("\(account) \(machineId) \(nodeKey) \(on.map { "\($0)" } ?? "default") \(name)")
                    guard hasKey else { return nil }
                    return ["v": 1, "grantor": "mac-0011223344556677", "account": account, "machineId": machineId, "nodeKey": nodeKey,
                            "control": change, "screen": change]
                },
                thisMacName: { "Studio" },
                now: { [self] in now })
        }

        var methods: [String] { calls.map(\.method) }
    }

    static let mini = JoinedMachine(id: "m_1", name: "mini-7", state: .online, platform: "macos", meshPeerId: "Tk9ERQ==")

    /// Waits (bounded) for the store's reads, which run as their own tasks, to land.
    private static func settle(_ done: @MainActor () -> Bool) async throws {
        for _ in 0..<10_000 where !done() { await Task.yield() }
        try #require(done())
    }

    private static func page(_ store: RemoteControlConsent, _ machines: [JoinedMachine], thisMac: String? = nil) throws -> [String: Any] {
        let data = try #require(store.pageData(machines: machines, thisMac: thisMac))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func rows(_ page: [String: Any]) -> [[String: Any]] { page["rows"] as? [[String: Any]] ?? [] }

    /// Only machines the person owns that can take a grant get a row (not revoked, with a mesh id), never
    /// this Mac itself; nothing is read until the page draws, and a drawn row reads once.
    @Test func rowsAreTheOwnedJoinedMachinesAndReadOnlyWhenDrawn() async throws {
        let fake = Fake()
        let store = RemoteControlConsent(services: fake.services())
        #expect(fake.calls.isEmpty, "nothing reads before the page draws")
        let machines = [Self.mini,
                        JoinedMachine(id: "m_2", name: "gone", state: .revoked, meshPeerId: "R09ORQ=="),
                        JoinedMachine(id: "m_3", name: "no-mesh", state: .online),
                        JoinedMachine(id: "m_self", name: "Studio", state: .online, meshPeerId: "U0VMRg==")]
        let first = try Self.page(store, machines, thisMac: "m_self")
        #expect(first["title"] as? String == RemoteControlStrings.title)
        #expect(first["this_mac_words"] is NSNull)
        #expect(Self.rows(first).map { $0["id"] as? String } == ["m_1"])
        #expect(Self.rows(first).first?["status"] as? String == "unknown")
        try await Self.settle { store.entries["m_1"] != nil }
        #expect(fake.methods == ["_acpmux/consent_remote_status"])
        #expect(fake.calls.first?.params["daemonId"] as? String == "Tk9ERQ==")
        let second = try Self.page(store, machines, thisMac: "m_self")
        #expect(second["this_mac_words"] as? [String] == ["amber", "birch", "cedar", "delta"])
        let row = try #require(Self.rows(second).first)
        #expect(row["status"] as? String == "off" && row["on"] as? Bool == false && row["online"] as? Bool == true)
        #expect(row["words"] is NSNull)
        #expect(fake.methods.count == 1, "a known row is not read again until the page shows again")
        store.pageShown()
        _ = try Self.page(store, machines, thisMac: "m_self")
        try await Self.settle { fake.methods.count == 2 }
    }

    /// RED-first: the platform supplies the machine list, so a row could name another machine than the one
    /// that answers. Before signing, the answer's machine id and node key must equal the row's; on a
    /// mismatch nothing is signed or sent.
    @Test func aMismatchedMachineOrNodeKeyIsRefusedBeforeSigning() async throws {
        let fake = Fake()
        let store = RemoteControlConsent(services: fake.services())
        fake.status = Fake.answer(machineId: "m_other", control: false)
        #expect(await store.set(Self.mini, on: true) == RemoteControlStrings.mismatch("mini-7"))
        fake.status = Fake.answer(nodeKey: "T1RIRVI=", control: false)
        #expect(await store.set(Self.mini, on: true) == RemoteControlStrings.mismatch("mini-7"))
        #expect(fake.signs.isEmpty, "nothing was signed")
        #expect(!fake.methods.contains("_acpmux/consent_remote_set"))
        let row = try #require(Self.rows(try Self.page(store, [Self.mini])).first)
        #expect(row["status"] as? String == "error" && row["detail"] as? String == RemoteControlStrings.mismatch("mini-7"))
    }

    /// A target enrolled under another account would refuse the grant anyway: nothing is signed for it.
    @Test func aMachineUnderAnotherAccountGetsNoGrant() async {
        let fake = Fake()
        let store = RemoteControlConsent(services: fake.services())
        fake.status = Fake.answer(account: "user_other", control: false)
        #expect(await store.set(Self.mini, on: true) == RemoteControlStrings.otherAccount("mini-7"))
        #expect(fake.signs.isEmpty)
    }

    /// One switch sets Control and Screen sharing together, signed for the account `self` names, sent to
    /// the row's node key, then read again; an off signs an off for both.
    @Test func aSetSignsBothSurfacesForTheStatusAccountAndReadsAgain() async throws {
        let fake = Fake()
        let store = RemoteControlConsent(services: fake.services())
        #expect(await store.set(Self.mini, on: true) == nil)
        #expect(fake.signs == ["user_abc m_1 Tk9ERQ== true Studio"])
        #expect(fake.methods == ["_acpmux/consent_remote_status", "_acpmux/consent_remote_set", "_acpmux/consent_remote_status"])
        let sent = try #require(fake.calls[1].params["grant"] as? [String: any Sendable])
        #expect(fake.calls[1].params["daemonId"] as? String == "Tk9ERQ==")
        #expect(sent["control"] as? String == "on" && sent["screen"] as? String == "on")
        #expect(await store.set(Self.mini, on: false) == nil)
        #expect(fake.signs.last == "user_abc m_1 Tk9ERQ== false Studio")
        let off = try #require(fake.calls[4].params["grant"] as? [String: any Sendable])
        #expect(off["control"] as? String == "off" && off["screen"] as? String == "off")
    }

    /// The first grant to a machine that has not trusted this Mac's key leaves an ask there: the row shows
    /// the words to check on that machine. Once it trusts the key, the row is a plain switch again.
    @Test func anUnpinnedTargetShowsTheAskWithTheWords() async throws {
        let fake = Fake()
        let store = RemoteControlConsent(services: fake.services())
        fake.status = Fake.answer(control: false, pinned: false)
        fake.setAnswer = ["ok": false, "reason": "grant.unpinned", "error": "not trusted yet", "words": ["amber", "birch", "cedar", "delta"]]
        #expect(await store.set(Self.mini, on: true) == nil)
        let row = try #require(Self.rows(try Self.page(store, [Self.mini])).first)
        #expect(row["status"] as? String == "ask_pending")
        #expect(row["words"] as? [String] == ["amber", "birch", "cedar", "delta"])
        #expect(row["detail"] as? String == RemoteControlStrings.askPending("mini-7", words: ["amber", "birch", "cedar", "delta"]))
        fake.status = Fake.answer(control: true, pinned: true, log: [["at": 1_794_781_500_000, "event": "grant", "by": "mac-0011223344556677",
                                                                       "surface": "control", "name": "Studio"]])
        fake.setAnswer = ["ok": true]
        #expect(await store.set(Self.mini, on: true) == nil)
        let on = try #require(Self.rows(try Self.page(store, [Self.mini])).first)
        #expect(on["status"] as? String == "on" && on["on"] as? Bool == true)
        #expect((on["detail"] as? String)?.hasPrefix(RemoteControlStrings.onFrom(RemoteControlStrings.thisMac)) == true)
        #expect((on["log"] as? [[String: Any]])?.count == 1)
    }

    /// SECURITY (review of #44003, B1): the words the owner Mac shows for the target's ask are this Mac's own key's,
    /// from this Mac's acpmux (`self.words`), never what the far machine answered: whoever answered the dial could
    /// name another key's words, and the person's comparison on the target is the only check of the key.
    @Test func theAskShowsThisMacsOwnWordsNeverTheFarAnswers() async throws {
        let fake = Fake()
        let store = RemoteControlConsent(services: fake.services())
        fake.status = Fake.answer(control: false, pinned: false)
        fake.setAnswer = ["ok": false, "reason": "grant.unpinned", "error": "not trusted yet", "words": ["zebra", "yacht", "xenon", "wharf"]]
        #expect(await store.set(Self.mini, on: true) == nil)
        let row = try #require(Self.rows(try Self.page(store, [Self.mini])).first)
        #expect(row["words"] as? [String] == ["amber", "birch", "cedar", "delta"])
        #expect((row["detail"] as? String)?.contains("zebra") == false)
    }

    /// A failure on this Mac of an account set (`self.ok` false, though the answer's `ok` is true) is shown.
    @Test func anAccountSetRefusedOnThisMacShowsItsError() async throws {
        let fake = Fake()
        var services = fake.services()
        services.shown = { true }
        var record = JoinConsentRecord()
        record.account = "user_abc"
        services.record = { record }
        let store = RemoteControlConsent(services: services)
        fake.accountAnswer = ["ok": true, "self": ["ok": false, "reason": "grant.unpinned", "error": "this Mac's key is not trusted here yet"],
                              "applied": [] as [Any]]
        #expect(await store.setAccount(on: true) == "this Mac's key is not trusted here yet")
    }

    /// An unreachable machine shows Offline; a refusal other than the ask shows the target's own line; no key, no grant.
    @Test func offlineRefusedAndKeylessRows() async throws {
        let fake = Fake()
        let store = RemoteControlConsent(services: fake.services())
        fake.status = ["ok": false, "reason": "machine.unreachable", "error": "no route"]
        _ = try Self.page(store, [Self.mini])
        try await Self.settle { store.entries["m_1"] != nil }
        let offline = try #require(Self.rows(try Self.page(store, [Self.mini])).first)
        #expect(offline["status"] as? String == "offline" && offline["online"] as? Bool == false)
        #expect(await store.set(Self.mini, on: true) == RemoteControlStrings.offline)
        #expect(fake.signs.isEmpty)
        fake.status = Fake.answer(control: false)
        fake.setAnswer = ["ok": false, "reason": "grant.expired", "error": "the grant expired"]
        #expect(await store.set(Self.mini, on: true) == "the grant expired")
        fake.hasKey = false
        #expect(await store.set(Self.mini, on: true) == RemoteControlStrings.noKey)
    }

    /// A machine that leaves the list is forgotten with what it showed.
    @Test func aMachineThatLeavesIsForgotten() async throws {
        let fake = Fake()
        let store = RemoteControlConsent(services: fake.services())
        _ = try Self.page(store, [Self.mini])
        try await Self.settle { store.entries["m_1"] != nil }
        #expect(Self.rows(try Self.page(store, [])).isEmpty)
        #expect(store.entries.isEmpty)
    }

    /// The block (and every set from the page) exists only while devices_join shows: this Mac joined, with
    /// labs.machineJoin on. This Mac's own row, and a machine the list doesn't name, are never set.
    @Test func theBlockAndItsSetsNeedTheJoinBlockShown() async throws {
        let fake = Fake()
        var services = fake.services()
        var shown = false
        services.shown = { shown }
        services.thisMac = { "m_self" }
        services.machines = { [Self.mini, JoinedMachine(id: "m_self", name: "Studio", state: .online, meshPeerId: "U0VMRg==")] }
        let store = RemoteControlConsent(services: services)
        #expect(store.hostJSON == .null)
        #expect(await store.set(machineID: "m_1", on: true) == RemoteControlStrings.notOwned)
        #expect(fake.calls.isEmpty && fake.signs.isEmpty)
        shown = true
        guard case .object(let block) = store.hostJSON, case .array(let rows) = block["rows"] else {
            Issue.record("devices_control is not an object with rows")
            return
        }
        #expect(rows.count == 1)
        #expect(await store.set(machineID: "m_self", on: true) == RemoteControlStrings.notOwned)
        #expect(await store.set(machineID: "m_9", on: true) == RemoteControlStrings.notOwned)
        #expect(await store.set(machineID: "m_1", on: true) == nil)
        #expect(fake.signs == ["user_abc m_1 Tk9ERQ== true Studio"])
    }

    /// Contract v2 C: a sign-in on this Mac turns Control between the person's devices on with one `*` grant,
    /// only while acpmux has no account-wide grant (`accountPolicy` null) and the Labs switch is on. A policy
    /// already there (even off), an acpmux that reports none, or Labs off: nothing is signed.
    @Test func aSignInTurnsTheAccountOnOnlyWithoutAPolicy() async {
        let fake = Fake()
        var services = fake.services()
        var enabled = false
        services.enabled = { enabled }
        services.refreshRecord = { [fake] in fake.recordReads += 1 }
        let store = RemoteControlConsent(services: services)
        await store.signedIn()
        #expect(fake.calls.isEmpty && fake.signs.isEmpty, "Labs off: nothing")
        enabled = true
        await store.signedIn()
        #expect(fake.signs == ["user_abc * * default Studio"])
        #expect(fake.methods == ["_acpmux/machine_consent_get", "_acpmux/consent_account_set"])
        let grant = fake.calls.last?.params["grant"] as? [String: any Sendable]
        #expect(grant?["machineId"] as? String == "*" && grant?["nodeKey"] as? String == "*" && grant?["control"] as? String == "default")
        #expect(fake.recordReads == 1)
        fake.record["accountPolicy"] = ["grantor": "mac-0011223344556677", "issuedAt": 1000, "control": "off", "screen": "off"]
        await store.signedIn()
        fake.record["accountPolicy"] = nil
        await store.signedIn()
        #expect(fake.signs.count == 1, "a policy (even off), or an acpmux that reports none, signs nothing")
    }

    /// The switch for all devices: only while the block shows; it signs one `*` grant for this Mac's account,
    /// sends it to acpmux, reads this Mac's record again, and shows acpmux's refusal. Its row reads the policy.
    @Test func theAccountSwitchSignsStarAndShowsThePolicy() async throws {
        let fake = Fake()
        var services = fake.services()
        var shown = false
        services.shown = { shown }
        var record = JoinConsentRecord()
        record.account = "user_abc"
        services.record = { record }
        let store = RemoteControlConsent(services: services)
        #expect(await store.setAccount(on: true) == RemoteControlStrings.notOwned)
        #expect(fake.signs.isEmpty)
        shown = true
        #expect(await store.setAccount(on: false) == nil)
        #expect(fake.signs == ["user_abc * * false Studio"])
        #expect(fake.methods == ["_acpmux/consent_account_set"])
        fake.accountAnswer = ["ok": false, "error": "not this Mac's key"]
        #expect(await store.setAccount(on: true) == "not this Mac's key")
        record.accountPolicy = .init(grantor: "mac-0011223344556677", issuedAt: 1000, control: true, screen: true)
        let page = try Self.page(store, [])
        let account = try #require(page["account"] as? [String: Any])
        #expect(account["on"] as? Bool == true && account["busy"] as? Bool == false)
        #expect(account["title"] as? String == RemoteControlStrings.accountTitle)
        #expect(account["error"] as? String == "not this Mac's key")
        #expect(page["title"] as? String == "Control between my devices")
        #expect(page["refresh"] as? String == RemoteControlStrings.refresh)
        #expect(await store.refreshTrust() == "not this Mac's key")
        #expect(fake.methods.last == "_acpmux/consent_trust_refresh")
    }

    /// A machine following the account's switch says so (`source`, "On for all your devices"), the Screen
    /// Sharing rows read the same through ``RemoteControlConsent/state(for:)``, and a per-machine nil signs
    /// `default` (back to the account's).
    @Test func aRowShowsItsSourceAndDefaultSignsDefault() async throws {
        let fake = Fake()
        var services = fake.services()
        services.shown = { true }
        services.machines = { [Self.mini] }
        let store = RemoteControlConsent(services: services)
        var answer = Fake.answer(control: true)
        answer["effective"] = ["control": ["on": true, "source": "account"], "screen": ["on": true, "source": "account"]]
        fake.status = answer
        #expect(store.state(for: "m_1")?.source == RemoteControlConsent.State.Source.none)
        try await Self.settle { store.entries["m_1"] != nil }
        #expect(store.state(for: "m_1") == RemoteControlConsent.State(on: true, source: .account, busy: false, error: nil))
        #expect(store.state(for: "m_9") == nil)
        let row = try #require(Self.rows(try Self.page(store, [Self.mini])).first)
        #expect(row["source"] as? String == "account" && row["detail"] as? String == RemoteControlStrings.accountOn)
        #expect(await store.set(machineID: "m_1", on: nil) == nil)
        #expect(fake.signs == ["user_abc m_1 Tk9ERQ== default Studio"])
        let sent = fake.calls.first { $0.method == "_acpmux/consent_remote_set" }?.params["grant"] as? [String: any Sendable]
        #expect(sent?["control"] as? String == "default" && sent?["screen"] as? String == "default")
    }
}
