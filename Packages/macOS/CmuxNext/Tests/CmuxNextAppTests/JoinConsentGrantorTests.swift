@testable import CmuxNextServer
import Foundation
import Testing

/// The target side of signed Control grants on this Mac's join block: the pending ask of another Mac's
/// key (`grantorAsk`) and the trusted keys (`grantors`) from `machine_consent_get`, shown as
/// `devices_join.grantor_ask` and `.grantors`, and the Allow / Not Now / Remove that answer them over a
/// line acpmux proved as the person.
@MainActor @Suite(.serialized) struct JoinConsentGrantorTests {
    @MainActor final class Line: JoinConsentLine {
        let isPerson: Bool
        let supportsConsent = true
        let record: JoinConsentRecord
        var trusts: [String] = []
        init(person: Bool, record: JoinConsentRecord) {
            isPerson = person
            self.record = record
        }
        func read() async -> JoinConsentRecord? { record }
        func set(_ surface: JoinConsentSurface, granted: Bool, ticket: JoinConsentGrantTicket?) async -> JoinConsentRecord? { nil }
        /// acpmux takes `_acpmux/consent_grantor_trust` only from the person's line.
        func call(_ method: String, _ params: [String: Any]) async -> Result<[String: Any], RemoteControlCallError> {
            guard method == "_acpmux/consent_grantor_trust", let id = params["id"] as? String, let trusted = params["trusted"] as? Bool else {
                return .failure(RemoteControlCallError("unknown"))
            }
            trusts.append("\(id) \(trusted)")
            return isPerson ? .success([:]) : .failure(RemoteControlCallError("not the person"))
        }
        func close() {}
    }

    static let result: [String: Any] = [
        "consent": ["screen": "none", "control": "granted"],
        "grantorAsk": ["id": "mac-0011223344556677", "name": "Studio", "from": "studio.local", "at": 1_794_781_755_488,
                       "words": ["amber", "birch", "cedar", "delta"]],
        "grantors": [["id": "mac-8899aabbccddeeff", "name": "Laptop", "fingerprint": "8899", "words": ["echo", "fjord", "grove", "harbor"],
                      "pinnedAt": 1_794_781_000_000]],
    ]

    private static func model(person: Bool, record: JoinConsentRecord?, lines: @escaping (Line) -> Void = { _ in }) -> JoinConsentModel {
        let parsed = record ?? JoinConsentRecord()
        return JoinConsentModel(services: JoinConsentServices(
            status: { JoinStatus(credentialPresent: true, machineId: "m_1", teamId: "t_1", name: "mini-7") },
            openLine: {
                let line = Line(person: person, record: parsed)
                lines(line)
                return line
            },
            enabled: { true }, askShown: { true }, markAskShown: {}))
    }

    /// RED-first: an older record had no `grantorAsk` or `grantors`; both parse, and a missing pair reads as none.
    @Test func theRecordCarriesTheAskAndTheTrustedKeys() throws {
        let record = try #require(JoinConsentRecord.parse(Self.result))
        #expect(record.control && !record.screen)
        #expect(record.grantorAsk == JoinConsentGrantor(id: "mac-0011223344556677", name: "Studio", words: ["amber", "birch", "cedar", "delta"],
                                                        from: "studio.local", at: 1_794_781_755_488))
        #expect(record.grantors.map(\.id) == ["mac-8899aabbccddeeff"] && record.grantors.first?.at == 1_794_781_000_000)
        let old = try #require(JoinConsentRecord.parse(["consent": ["screen": "granted"]]))
        #expect(old.grantorAsk == nil && old.grantors.isEmpty)
    }

    /// `devices_join` shows the ask with its words and both answers, and each trusted Mac with its Remove;
    /// with no ask, `grantor_ask` is an explicit null so the page clears it.
    @Test func theJoinBlockShowsTheAskAndTheTrustedMacs() async throws {
        let model = Self.model(person: true, record: JoinConsentRecord.parse(Self.result))
        await model.refresh()
        let pageData = try #require(model.pageData())
        let page = try #require(try JSONSerialization.jsonObject(with: pageData) as? [String: Any])
        let ask = try #require(page["grantor_ask"] as? [String: Any])
        #expect(ask["id"] as? String == "mac-0011223344556677")
        #expect(ask["words"] as? [String] == ["amber", "birch", "cedar", "delta"])
        #expect(ask["title"] as? String == JoinConsentStrings.grantorAskTitle("Studio"))
        #expect(ask["help"] as? String == JoinConsentStrings.grantorAskHelp("Studio"))
        #expect(ask["allow"] as? String == JoinConsentStrings.grantorAllow && ask["dismiss"] as? String == JoinConsentStrings.grantorDismiss)
        let grantors = try #require(page["grantors"] as? [[String: Any]])
        #expect(grantors.count == 1 && grantors.first?["title"] as? String == "Laptop")
        #expect(grantors.first?["remove"] as? String == JoinConsentStrings.grantorRemove)
        #expect(grantors.first?["subtitle"] as? String == JoinConsentStrings.grantorSubtitle(words: ["echo", "fjord", "grove", "harbor"]))

        let none = Self.model(person: true, record: JoinConsentRecord())
        await none.refresh()
        let plainData = try #require(none.pageData())
        let plain = try #require(try JSONSerialization.jsonObject(with: plainData) as? [String: Any])
        #expect(plain["grantor_ask"] is NSNull)
        #expect((plain["grantors"] as? [Any])?.isEmpty == true)
    }

    /// A trust goes only over the person's line; Not Now and Remove (an untrust) go over any line acpmux takes.
    @Test func aTrustNeedsThePersonsLine() async throws {
        var opened: [Line] = []
        let notPerson = Self.model(person: false, record: JoinConsentRecord()) { opened.append($0) }
        await notPerson.refresh()
        #expect(await notPerson.trustGrantor("mac-0011223344556677", trusted: true) == JoinConsentStrings.grantorTrustFailed)
        #expect(opened.allSatisfy { $0.trusts.isEmpty }, "no trust reached acpmux")
        let person = Self.model(person: true, record: JoinConsentRecord()) { opened.append($0) }
        await person.refresh()
        #expect(await person.trustGrantor("mac-0011223344556677", trusted: true) == nil)
        #expect(await person.trustGrantor("mac-0011223344556677", trusted: false) == nil)
        #expect(opened.flatMap(\.trusts) == ["mac-0011223344556677 true", "mac-0011223344556677 false"])
    }

    /// The skip decision for Mac Screen's approval panel: acpmux answers `_acpmux/consent_screen_auto` over the
    /// person's line, with the surface the request's scope names; only `allowed: true` skips the panel.
    @MainActor final class AutoLine: JoinConsentLine {
        let isPerson: Bool
        let supportsConsent = true
        var answer: Result<[String: Any], RemoteControlCallError>
        var asked: [[String: Any]] = []
        init(person: Bool, answer: Result<[String: Any], RemoteControlCallError>) {
            isPerson = person
            self.answer = answer
        }
        func read() async -> JoinConsentRecord? { nil }
        func set(_ surface: JoinConsentSurface, granted: Bool, ticket: JoinConsentGrantTicket?) async -> JoinConsentRecord? { nil }
        func call(_ method: String, _ params: [String: Any]) async -> Result<[String: Any], RemoteControlCallError> {
            guard method == "_acpmux/consent_screen_auto" else { return .failure(RemoteControlCallError("unknown")) }
            asked.append(params)
            return answer
        }
        func close() {}
    }

    /// With the Labs switch off this Mac shows no joined consent, so no request skips the panel and acpmux is not asked.
    @Test func screenAutoIsOffWithTheLabsSwitchOff() async {
        var opened = 0
        let model = JoinConsentModel(services: JoinConsentServices(
            status: { nil }, openLine: {
                opened += 1
                return AutoLine(person: true, answer: .success(["allowed": true]))
            }, enabled: { false }, askShown: { true }, markAskShown: {}))
        #expect(await !model.screenAuto(control: false, viewerId: "d-phone", viewerName: "Phone"))
        #expect(opened == 0)
    }

    @Test func screenAutoAllowsOnlyOnAcpmuxsYesOverThePersonsLine() async {
        var lines: [AutoLine] = []
        var person = true
        var answer: Result<[String: Any], RemoteControlCallError> = .success(["allowed": true])
        let model = JoinConsentModel(services: JoinConsentServices(
            status: { nil }, openLine: {
                let line = AutoLine(person: person, answer: answer)
                lines.append(line)
                return line
            }, enabled: { true }, askShown: { true }, markAskShown: {}))
        #expect(await model.screenAuto(control: true, viewerId: "d-phone", viewerName: "Phone"))
        #expect(lines.last?.asked.first?["surface"] as? String == "control" && lines.last?.asked.first?["viewerId"] as? String == "d-phone")
        #expect(lines.last?.asked.first?["hubUser"] == nil, "the hub's user id is another id space")
        #expect(await model.screenAuto(control: false, viewerId: "d-phone", viewerName: "Phone"))
        #expect(lines.last?.asked.first?["surface"] as? String == "screen")
        answer = .success(["allowed": false])
        #expect(await !model.screenAuto(control: true, viewerId: "d-phone", viewerName: "Phone"))
        answer = .success([:])
        #expect(await !model.screenAuto(control: true, viewerId: "d-phone", viewerName: "Phone"))
        answer = .failure(RemoteControlCallError("no daemon"))
        #expect(await !model.screenAuto(control: true, viewerId: "d-phone", viewerName: "Phone"))
        answer = .success(["allowed": true])
        person = false
        #expect(await !model.screenAuto(control: true, viewerId: "d-phone", viewerName: "Phone"))
        #expect(lines.last?.asked.isEmpty == true, "nothing goes out over a line that is not the person's")
    }
}
