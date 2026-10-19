@testable import CmuxNextErrorJournal
import Foundation
import Testing

/// The journal folds occurrences by fingerprint, redacts, bounds disk and memory, and keeps
/// what it saw across launches.
struct ErrorJournalTests {
    private let directory = FileManager().temporaryDirectory.appendingPathComponent("error-journal-\(UUID().uuidString)")
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ message: String, source: String = "app", level: ErrorLevel = .error, at offset: TimeInterval = 0,
                       frame: String? = nil) -> ErrorEvent {
        ErrorEvent(source: source, level: level, message: message, topFrame: frame, date: base.addingTimeInterval(offset))
    }

    @Test func occurrencesThatDifferOnlyInValuesFoldIntoOneEntry() async throws {
        let journal = ErrorJournal(directory: directory)
        await journal.record(event("load of /Users/a/one.json failed after 512 ms", at: 0))
        await journal.record(event("load of /Users/b/two.json failed after 9 ms", at: 5))
        await journal.record(event("load of /Users/b/two.json failed after 9 ms", level: .fault, at: 2))
        let entries = await journal.entries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.count == 3)
        #expect(entry.level == .fault)
        #expect(entry.template == "load of <path> failed after <n> ms")
        #expect(entry.sample.contains("two.json"))
        #expect(entry.firstMs == Int64(base.timeIntervalSince1970 * 1000))
        #expect(entry.lastMs == Int64(base.addingTimeInterval(5).timeIntervalSince1970 * 1000))
    }

    @Test func differentSourcesOrFramesStayApart() async {
        let journal = ErrorJournal(directory: directory)
        await journal.record(event("boom"))
        await journal.record(event("boom", source: "acpmux"))
        await journal.record(event("boom", frame: "main.tsx:12"))
        #expect(await journal.entryCount == 3)
    }

    @Test func secretsNeverReachTheSampleOrTheDisk() async throws {
        let journal = ErrorJournal(directory: directory)
        await journal.record(ErrorEvent(source: "app", level: .error,
                                        message: "request failed Authorization: Bearer sk-ant-abcdefghijklmnop1234 cookie=sess=xyz https://u:pw@h.example/x?token=s3cret&a=1",
                                        context: ["header": "x-api-key: AKIAABCDEFGHIJKLMNOP"]))
        await journal.flush()
        let entry = try #require(await journal.entries().first)
        for secret in ["sk-ant-abcdefghijklmnop1234", "sess=xyz", "pw@", "s3cret", "AKIAABCDEFGHIJKLMNOP"] {
            #expect(!entry.sample.contains(secret), "sample kept \(secret)")
            #expect(!(entry.context["header"] ?? "").contains(secret))
        }
        let files = try FileManager().contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".ndjson") }
        let disk = try files.map { try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }.joined()
        #expect(!disk.contains("sk-ant-abcdefghijklmnop1234"))
        #expect(!disk.contains("s3cret"))
        #expect(disk.contains("request failed"))
    }

    @Test func aNewLaunchReadsWhatTheLastOneKept() async {
        let first = ErrorJournal(directory: directory)
        await first.record(event("socket closed 3 times"))
        await first.record(event("socket closed 4 times", at: 1))
        await first.flush()
        let second = ErrorJournal(directory: directory)
        let entries = await second.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.count == 2)
        await second.record(event("socket closed 5 times", at: 2))
        await second.flush()
        #expect(await ErrorJournal(directory: directory).entries().first?.count == 3)
    }

    @Test func compactionKeepsDiskBoundedAndEntriesAlive() async {
        let limits = ErrorJournalLimits(segmentBytes: 4096, maxEntries: 50, flushBatch: 1)
        let journal = ErrorJournal(directory: directory, limits: limits)
        for round in 0..<200 {
            await journal.record(event("failure kind \(["alpha", "beta", "gamma"][round % 3])", at: Double(round)))
        }
        await journal.flush()
        #expect(await journal.diskBytes <= 2 * limits.segmentBytes)
        let reopened = await ErrorJournal(directory: directory, limits: limits).entries(ErrorQuery(order: .count))
        #expect(reopened.count == 3)
        #expect(reopened.map(\.count).reduce(0, +) == 200)
        let segments = (try? FileManager().contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".ndjson") }) ?? []
        #expect(segments.count == 1)
    }

    @Test func aStormOfDistinctErrorsBecomesOneCountedEntry() async {
        let journal = ErrorJournal(directory: directory, limits: ErrorJournalLimits(newFingerprintsPerMinute: 3))
        for word in ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"] {
            await journal.record(event("unknown key \(word)"))
        }
        let entries = await journal.entries(ErrorQuery(order: .count))
        #expect(entries.count == 4)
        #expect(entries.first?.template == "too many distinct errors from app")
        #expect(entries.first?.count == 3)
    }

    @Test func theLeastRecentlySeenAreEvictedPastTheLimit() async {
        let journal = ErrorJournal(directory: directory, limits: ErrorJournalLimits(maxEntries: 10))
        for index in 0..<30 {
            await journal.record(event("error \(["a", "b", "c", "d", "e", "f"][index % 6])\(String(repeating: "x", count: index))", at: Double(index)))
        }
        let entries = await journal.entries(ErrorQuery(limit: 100))
        #expect(entries.count <= 10)
        #expect(entries.first?.sample.hasSuffix(String(repeating: "x", count: 29)) == true)
    }

    @Test func queriesFilterBySourceLevelTextAndTime() async {
        let journal = ErrorJournal(directory: directory)
        await journal.record(event("page broke", source: "page:settings", level: .warning, at: 0))
        await journal.record(event("pool failed", source: "acpmux", level: .error, at: 10))
        await journal.record(event("pool failed", source: "acpmux", level: .error, at: 11))
        await journal.record(event("crash cmux", source: "crash", level: .crash, at: 20))
        #expect(await journal.entries(ErrorQuery(sources: ["page"])).map(\.source) == ["page:settings"])
        #expect(await journal.entries(ErrorQuery(minimumLevel: .error)).count == 2)
        #expect(await journal.entries(ErrorQuery(text: "POOL")).count == 1)
        #expect(await journal.entries(ErrorQuery(since: base.addingTimeInterval(15))).map(\.source) == ["crash"])
        #expect(await journal.entries(ErrorQuery(order: .count)).first?.source == "acpmux")
        #expect(await journal.entries(ErrorQuery(limit: 1)).first?.source == "crash")
    }

    @Test func clearForgetsChosenOrAllEntries() async {
        let journal = ErrorJournal(directory: directory)
        await journal.record(event("one"))
        await journal.record(event("two"))
        let fingerprint = await journal.entries().first!.fingerprint
        #expect(await journal.clear(fingerprints: [fingerprint]) == 1)
        #expect(await ErrorJournal(directory: directory).entryCount == 1)
        #expect(await journal.clear() == 1)
        #expect(await ErrorJournal(directory: directory).entryCount == 0)
    }

    @Test func aFailingSourceIsReportedAndTheOthersStillRun() async {
        struct Broken: ErrorHarvestSource {
            let id = "broken"
            func collect(after cursor: String?) async throws -> ErrorHarvest { throw CocoaError(.fileReadNoPermission) }
        }
        struct Fixed: ErrorHarvestSource {
            let id = "fixed"
            func collect(after cursor: String?) async throws -> ErrorHarvest {
                ErrorHarvest(events: cursor == nil ? [ErrorEvent(source: "acpmux", level: .warning, message: "slow")] : [],
                             cursor: "1")
            }
        }
        let journal = ErrorJournal(directory: directory)
        let found = await journal.harvest([Broken(), Fixed()])
        #expect(found["fixed"] == 1)
        #expect(await journal.entries(ErrorQuery(sources: ["journal"])).count == 1)
        // The cursor was saved: a second harvest finds nothing new.
        #expect(await ErrorJournal(directory: directory).harvest([Fixed()])["fixed"] == 0)
    }
}
