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

    @Test func prefixedCredentialAssignmentsNeverReachTheJournal() async throws {
        let journal = ErrorJournal(directory: directory)
        let values = ["ordinarySecret123", "ordinary-api-value", "ordinary-password", "camel-secret-value"]
        await journal.record(event(
            "failed AWS_SECRET_ACCESS_KEY=\(values[0]) MY_API_KEY=\(values[1]) "
                + "the_password=\(values[2]) secretAccessKey=\(values[3])"
        ))
        await journal.flush()

        let entry = try #require(await journal.entries().first)
        for value in values {
            #expect(!entry.sample.contains(value))
        }
    }

    @Test func completeCookieHeadersNeverReachTheJournal() async throws {
        let journal = ErrorJournal(directory: directory)
        let values = ["first-cookie", "second-cookie"]
        await journal.record(event("request failed Cookie: session=\(values[0]); csrf=\(values[1])"))

        let entry = try #require(await journal.entries().first)
        for value in values {
            #expect(!entry.sample.contains(value))
        }
    }

    @Test func escapedAssignmentsAndNamespacedQuerySecretsNeverReachTheJournal() async throws {
        let journal = ErrorJournal(directory: directory)
        let values = [
            "escaped-password", "raw-auth-value", "access-secret", "signature-secret", "encoded-credential-value",
            "quoted-tail-value", "embedded-query-value", "nested-url-value", "nested-query-value",
            "bare-tail-value", "bracket-tail-value", "question-tail-value", "comma-tail-value",
        ]
        await journal.record(event(
            #"provider {\"password\":\"\#(values[0])\"} failed ?auth[token]=\#(values[1])"#
                + #"&access_token[]=\#(values[2])&X-Amz-Signature=\#(values[3])&auth%5Btoken%5D=\#(values[4])"#
                + #" credential {\"password\":\"prefix\\\"\#(values[5])\"} request failed auth[token]=\#(values[6])"#
                + #" url=https://example.test/?auth[token]=\#(values[7]) query=auth[token]=\#(values[8])"#
                + #" password=alpha \#(values[9])"#
                + #" auth[password]=queryalpha \#(values[10]) completion_tokens=42"#
                + #" auth[token]=question-left?\#(values[11]) completion_tokens=43"#
                + #" auth[token]=comma-left,\#(values[12]) completion_tokens=44"#
        ))

        let entry = try #require(await journal.entries().first)
        for value in values {
            #expect(!entry.sample.contains(value))
        }
    }

    @Test func legacySegmentsAreRedactedBeforeTheyAreReturnedOrRewritten() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = ["legacy-secret-value", "legacy-password-value", "legacy-cookie-value"]
        let legacy = ErrorEntry(
            fingerprint: "legacy-fingerprint",
            source: "app",
            level: .error,
            template: "AWS_SECRET_ACCESS_KEY=\(values[0])",
            sample: "Pwd=\(values[1])",
            topFrame: "token=\(values[0])",
            context: ["header": "Cookie: session=\(values[2])"],
            count: 1,
            firstMs: 1,
            lastMs: 1
        )
        var line = try JSONEncoder().encode(legacy)
        line.append(UInt8(ascii: "\n"))
        let clean = ErrorEntry(
            fingerprint: legacy.fingerprint,
            source: legacy.source,
            level: legacy.level,
            template: "newest clean template",
            sample: "newest clean sample",
            topFrame: nil,
            context: [:],
            count: 2,
            firstMs: 1,
            lastMs: 2
        )
        line.append(try JSONEncoder().encode(clean))
        line.append(UInt8(ascii: "\n"))
        let segment = directory.appendingPathComponent("segment-000001.ndjson")
        try line.write(to: segment)

        let journal = ErrorJournal(directory: directory)
        let entry = try #require(await journal.entries().first)
        let memory = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        let segments = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "ndjson" }
        let disk = try segments.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        for value in values {
            #expect(!memory.contains(value))
            #expect(!disk.contains(value))
        }
    }

    @Test func migratedEntriesKeepTheirFingerprintContinuity() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = ErrorEntry(
            fingerprint: "legacy-fingerprint",
            source: "app",
            level: .error,
            template: "password=legacy-value",
            sample: "password=legacy-value",
            topFrame: nil,
            context: [:],
            count: 1,
            firstMs: 1,
            lastMs: 1
        )
        var line = try JSONEncoder().encode(legacy)
        line.append(UInt8(ascii: "\n"))
        try line.write(to: directory.appendingPathComponent("segment-000001.ndjson"))

        let journal = ErrorJournal(directory: directory)
        await journal.record(event("password=current-value", at: 1))

        #expect(await journal.entryCount == 1)
        #expect(await journal.entries().first?.count == 2)
    }

    @Test func migrationMergesEntriesThatCanonicalizeToOneFingerprint() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = ErrorEntry(
            fingerprint: "legacy-one",
            source: "app",
            level: .warning,
            template: "password=first-value",
            sample: "oldest-marker; password=first-value",
            topFrame: nil,
            context: ["generation": "old"],
            count: 2,
            firstMs: 1,
            lastMs: 2
        )
        let second = ErrorEntry(
            fingerprint: "legacy-two",
            source: "app",
            level: .fault,
            template: "password=second-value",
            sample: "newest-marker; password=second-value",
            topFrame: nil,
            context: ["generation": "new"],
            count: 3,
            firstMs: 3,
            lastMs: 4
        )
        var lines = try JSONEncoder().encode(first)
        lines.append(UInt8(ascii: "\n"))
        lines.append(try JSONEncoder().encode(second))
        lines.append(UInt8(ascii: "\n"))
        try lines.write(to: directory.appendingPathComponent("segment-000001.ndjson"))

        let entry = try #require(await ErrorJournal(directory: directory).entries().first)
        #expect(entry.count == 5)
        #expect(entry.level == .fault)
        #expect(entry.firstMs == 1)
        #expect(entry.lastMs == 4)
        #expect(entry.sample.contains("newest-marker"))
        #expect(entry.context["generation"] == "new")
    }

    @Test func failedLegacySegmentDeletionIsReportedAndRetried() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let value = "undeletable-legacy-value"
        let legacy = ErrorEntry(
            fingerprint: "legacy-fingerprint",
            source: "app",
            level: .error,
            template: "password=\(value)",
            sample: "password=\(value)",
            topFrame: nil,
            context: [:],
            count: 1,
            firstMs: 1,
            lastMs: 1
        )
        var line = try JSONEncoder().encode(legacy)
        line.append(UInt8(ascii: "\n"))
        let segment = directory.appendingPathComponent("segment-000001.ndjson")
        try line.write(to: segment)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: segment.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: segment.path) }

        let blocked = ErrorJournal(directory: directory)
        #expect(await blocked.writeError != nil)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: segment.path)
        await blocked.record(event("ordinary follow-up"))
        await blocked.flush()
        #expect(await blocked.writeError == nil)
        let segments = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "ndjson" }
        let disk = try segments.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(!disk.contains(value))
    }

    @Test func clearDoesNotReportSuccessWhenAnOldSegmentCannotBeDeleted() async throws {
        let journal = ErrorJournal(directory: directory)
        await journal.record(event("clear failure"))
        await journal.flush()
        let segment = try #require(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "ndjson" }
        )
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: segment.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: segment.path) }

        #expect(await journal.clear() == 0)
        #expect(await journal.writeError != nil)
        #expect(await journal.entryCount == 1)
        #expect(await ErrorJournal(directory: directory).entryCount == 1)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: segment.path)
        #expect(await journal.clear() == 1)
        #expect(await ErrorJournal(directory: directory).entryCount == 0)
    }

    @Test func journalArtifactsAreOwnerOnly() async throws {
        struct CursorSource: ErrorHarvestSource {
            let id = "cursor"
            func collect(after cursor: String?) async throws -> ErrorHarvest {
                ErrorHarvest(events: [], cursor: "next")
            }
        }

        let journal = ErrorJournal(directory: directory)
        await journal.record(event("private diagnostic"))
        await journal.flush()
        _ = await journal.harvest([CursorSource()])

        #expect(try permissions(of: directory) == 0o700)
        let artifacts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for artifact in artifacts where artifact.pathExtension == "ndjson" || artifact.lastPathComponent == "cursors.json" {
            #expect(try permissions(of: artifact) == 0o600, "\(artifact.lastPathComponent) was not owner-only")
        }
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

    /// `errors.list {"since_ms":1e300}` (or `"since":"1e300s"`) made `since`
    /// a date past Int64 milliseconds, and `Int64(_:)` trapped on a journal with an entry. A date
    /// past every entry matches none, one before every entry matches all.
    @Test func aSinceOutsideInt64MillisecondsMatchesWithoutTrapping() async {
        let journal = ErrorJournal(directory: directory)
        await journal.record(event("pool failed", source: "acpmux", at: 0))
        #expect(await journal.entries(ErrorQuery(since: Date(timeIntervalSince1970: 1e297))).isEmpty)
        #expect(await journal.entries(ErrorQuery(since: Date(timeIntervalSince1970: .infinity))).isEmpty)
        #expect(await journal.entries(ErrorQuery(since: Date(timeIntervalSince1970: -1e297))).count == 1)
        #expect(await journal.entries(ErrorQuery(since: Date(timeIntervalSince1970: -.infinity))).count == 1)
        #expect(await journal.entries(ErrorQuery(since: base)).count == 1)
        #expect(await journal.entries(ErrorQuery(since: base.addingTimeInterval(1))).isEmpty)
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

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
