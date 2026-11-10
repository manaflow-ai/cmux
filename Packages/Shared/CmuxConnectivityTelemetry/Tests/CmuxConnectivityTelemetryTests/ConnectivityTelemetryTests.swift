import Foundation
import Testing
@testable import CmuxConnectivityTelemetry

@Suite("Connectivity audience")
struct ConnectivityAudienceTests {
    @Test("Team domains are verbose, look-alikes are not", arguments: [
        ("aziz@manaflow.ai", ConnectivityAudience.team),
        ("  Lawrence@CMUX.com ", .team),
        ("leo@eng.manaflow.ai", .team),
        ("a@notmanaflow.ai", .everyone),
        ("a@manaflow.ai.example.com", .everyone),
        ("a@cmux.co", .everyone),
        ("@manaflow.ai", .everyone),
        ("manaflow.ai", .everyone),
        ("someone@gmail.com", .everyone),
    ])
    func classifies(email: String, expected: ConnectivityAudience) {
        #expect(ConnectivityAudience(email: email) == expected)
    }

    @Test func signedOutIsEveryone() {
        #expect(ConnectivityAudience(email: nil) == .everyone)
    }
}

@Suite("Connectivity policy")
struct ConnectivityPolicyTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func failure(_ offset: TimeInterval = 0) -> ConnectivityEvent {
        ConnectivityEvent(.link, "dial_failed", outcome: .failure,
                          fields: ["transport": .code("wireGuard"), "attempt": .number(3), "error": .text("udp 100.70.1.2:4101 refused")],
                          detail: "LinkError(code: offline, peer: abc123)", date: start.addingTimeInterval(offset))
    }

    @Test func teamKeepsEverythingUnsampled() {
        var policy = ConnectivityPolicy(configuration: .init(sampleEvery: 10, everyonePerHour: 1))
        for index in 0..<50 {
            let record = policy.admit(ConnectivityEvent(.link, "probe_ok", outcome: .success, date: start.addingTimeInterval(Double(index))),
                                      audience: .team)
            #expect(record?.sampleRate == 1)
        }
        let record = policy.admit(failure(), audience: .team)
        #expect(record?.detail == "LinkError(code: offline, peer: abc123)")
        #expect(record?.fields["error"] == .text("udp 100.70.1.2:4101 refused"))
    }

    @Test func everyoneLosesFreeText() throws {
        var policy = ConnectivityPolicy()
        let record = try #require(policy.admit(failure(), audience: .everyone))
        #expect(record.detail == nil)
        #expect(record.fields["error"] == nil)
        #expect(record.fields["transport"] == .code("wireGuard"))
        #expect(record.fields["attempt"] == .number(3))
        #expect(!record.jsonLine().contains("100.70"))
        #expect(!record.jsonLine().contains("abc123"))
    }

    @Test func everyoneDropsFieldsWhoseNameIsNotAWord() throws {
        var policy = ConnectivityPolicy()
        let event = ConnectivityEvent(.link, "dial_ok", outcome: .failure,
                                      fields: ["ms_remote_10_0_0_2": .number(4), "ms remote 10.0.0.2": .number(4), "ms_relay": .number(9)])
        let record = try #require(policy.admit(event, audience: .everyone))
        #expect(record.fields.keys.sorted() == ["ms_relay", "ms_remote_10_0_0_2"])
        #expect(ConnectivityEvent.Value.isSafeKey("ms_relay"))
        #expect(!ConnectivityEvent.Value.isSafeKey("ms remote 10.0.0.2"))
        #expect(!ConnectivityEvent.Value.isSafeKey("é"))
    }

    @Test func everyoneSamplesEachPhaseApart() {
        var policy = ConnectivityPolicy(configuration: .init(sampleEvery: 10, everyonePerHour: 1000))
        let connecting = ConnectivityEvent(.link, "phase", fields: ["phase": .code("connecting")], date: start)
        let connected = ConnectivityEvent(.link, "phase", outcome: .success, fields: ["phase": .code("connected")], date: start)
        #expect(policy.admit(connecting, audience: .everyone) != nil)
        #expect(policy.admit(connected, audience: .everyone) != nil)
        #expect(policy.admit(connecting, audience: .everyone) == nil)
    }

    @Test func foreignCodesThatAreNotWordsBecomeOther() {
        #expect(ConnectivityEvent.Value.safeCode("not_admitted") == .code("not_admitted"))
        #expect(ConnectivityEvent.Value.safeCode("dial 10.0.0.2 failed") == .code("other"))
        #expect(ConnectivityEvent.Value.safeCode("") == .code("other"))
    }

    @Test func everyoneSamplesRoutineStepsButKeepsEveryFailure() {
        var policy = ConnectivityPolicy(configuration: .init(sampleEvery: 10, everyonePerHour: 1000))
        var kept: [ConnectivityRecord] = []
        for index in 0..<25 {
            let event = ConnectivityEvent(.link, "probe_ok", outcome: .success, date: start.addingTimeInterval(Double(index)))
            if let record = policy.admit(event, audience: .everyone) { kept.append(record) }
        }
        #expect(kept.count == 3)
        #expect(kept.allSatisfy { $0.sampleRate == 10 })
        let failures = (0..<25).compactMap { policy.admit(failure(Double($0)), audience: .everyone) }
        #expect(failures.count == 25)
        #expect(failures.allSatisfy { $0.sampleRate == 1 })
    }

    @Test func everyoneHourlyBudgetCountsDrops() {
        var policy = ConnectivityPolicy(configuration: .init(sampleEvery: 1, everyonePerHour: 2))
        #expect(policy.admit(failure(0), audience: .everyone) != nil)
        #expect(policy.admit(failure(1), audience: .everyone) != nil)
        #expect(policy.admit(failure(2), audience: .everyone) == nil)
        #expect(policy.admit(failure(3), audience: .everyone) == nil)
        let next = policy.admit(failure(3601), audience: .everyone)
        #expect(next?.droppedBefore == 2)
    }
}

@Suite("Connectivity journal and recorder")
struct ConnectivityJournalTests {
    func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cct-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func journalKeepsEachValueKind() throws {
        let journal = ConnectivityJournal(directory: directory())
        let fields: [String: ConnectivityEvent.Value] = [
            "phase": .code("waiting"), "reason": .text("waiting"), "rtt_ms": .number(12.5), "relay_only": .flag(true),
        ]
        journal.append(ConnectivityRecord(date: Date(timeIntervalSince1970: 1_800_000_000.25), audience: .team, area: .link,
                                          name: "phase", outcome: .failure, fields: fields, detail: "d",
                                          sampleRate: 1, droppedBefore: 0))
        let record = try #require(journal.records().first)
        #expect(record.fields == fields)
        #expect(abs(record.date.timeIntervalSince1970 - 1_800_000_000.25) < 0.001)
    }

    @Test func aTeamJournalLeftByTheLastLaunchIsClearedForEveryone() async {
        let folder = directory()
        let earlier = ConnectivityTelemetry()
        earlier.setJournal(ConnectivityJournal(directory: folder))
        earlier.setAccount(email: "leo@cmux.com")
        earlier.record(.pairing, "requested", fields: ["phone": .text("abcd1234")])
        await earlier.flush()
        #expect(ConnectivityJournal(directory: folder).holdsTeamRecords())

        // The next launch starts as everyone and resolves signed out: no audience change, but the
        // team's journal must not survive for the next person.
        let next = ConnectivityTelemetry()
        next.setJournal(ConnectivityJournal(directory: folder))
        next.setAccount(email: nil)
        await next.flush()
        #expect(!ConnectivityJournal(directory: folder).contents().contains("abcd1234"))
    }

    @Test func journalRollsAndKeepsOrder() {
        let journal = ConnectivityJournal(url: directory().appendingPathComponent("c.jsonl"), maxBytes: 1024)
        for index in 0..<40 {
            journal.append(ConnectivityRecord(date: Date(timeIntervalSince1970: Double(index)), audience: .team, area: .hub,
                                              name: "bind", outcome: .success, fields: ["n": .number(Double(index))],
                                              detail: nil, sampleRate: 1, droppedBefore: 0))
        }
        let records = journal.records()
        #expect(!records.isEmpty)
        #expect(records.count < 40)
        let numbers = records.compactMap { if case .number(let n) = $0.fields["n"] { n } else { nil } }
        #expect(numbers == numbers.sorted())
        #expect(numbers.last == 39)
        let onDisk = ((try? FileManager.default.attributesOfItem(atPath: journal.url.path)[.size]) as? Int) ?? 0
        #expect(onDisk <= 1024)
    }

    @Test func recorderFollowsAccountAndClearsOnChange() async {
        let telemetry = ConnectivityTelemetry()
        let journal = ConnectivityJournal(directory: directory())
        telemetry.setJournal(journal)
        let seen = SeenRecords()
        telemetry.addSink { seen.add($0) }

        telemetry.record(.link, "dial_failed", outcome: .failure, detail: "before sign-in")
        await telemetry.flush()
        telemetry.setAccount(email: "aziz@manaflow.ai")
        await telemetry.flush()
        // Joining the team keeps everyone's earlier records (they hold no free text).
        #expect(journal.records().count == 1)
        #expect(journal.records().first?.detail == nil)
        telemetry.record(.link, "dial_failed", outcome: .failure, fields: ["error": .text("peer 10.0.0.4 timeout")],
                         detail: "full error")
        await telemetry.flush()
        #expect(journal.records().last?.detail == "full error")
        #expect(journal.records().last?.audience == .team)

        telemetry.setAccount(email: "someone@example.com")
        telemetry.record(.link, "dial_failed", outcome: .failure, fields: ["error": .text("peer 10.0.0.4 timeout")],
                         detail: "full error")
        await telemetry.flush()
        let after = journal.records()
        #expect(after.count == 1)
        #expect(after.first?.audience == .everyone)
        #expect(after.first?.detail == nil)
        #expect(!journal.contents().contains("10.0.0.4"))
        #expect(seen.all.map(\.audience) == [.everyone, .team, .everyone])
    }
}

final class SeenRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [ConnectivityRecord] = []
    func add(_ record: ConnectivityRecord) { lock.withLock { records.append(record) } }
    var all: [ConnectivityRecord] { lock.withLock { records } }
}

@Suite("Connectivity remote gate")
struct ConnectivityRemoteGateTests {
    func record(_ audience: ConnectivityAudience, _ outcome: ConnectivityEvent.Outcome, at seconds: TimeInterval) -> ConnectivityRecord {
        ConnectivityRecord(date: Date(timeIntervalSince1970: seconds), audience: audience, area: .phoneHost, name: "phase",
                           outcome: outcome, fields: [:], detail: nil, sampleRate: 1, droppedBefore: 0)
    }

    @Test func teamSendsEveryFailureEveryoneOnePerKeyPerHour() {
        var gate = ConnectivityRemoteGate()
        #expect((0..<5).allSatisfy { gate.sendsEvent(for: record(.team, .failure, at: Double($0))) })
        #expect(!gate.sendsEvent(for: record(.team, .success, at: 6)))
        #expect(gate.sendsEvent(for: record(.everyone, .failure, at: 10)))
        #expect(!gate.sendsEvent(for: record(.everyone, .failure, at: 20)))
        #expect(gate.sendsEvent(for: record(.everyone, .failure, at: 3611)))
    }
}
