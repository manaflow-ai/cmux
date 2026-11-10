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
