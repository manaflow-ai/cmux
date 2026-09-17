import Foundation
import Testing
@testable import CmuxAgentSessionStore

@Suite("Amp hook session repository")
struct AmpHookSessionRepositoryTests {
    @Test("records are decoded lossily, validated, sorted, searched, and paginated")
    func parsingAndQuerying() async throws {
        let fixture = try TemporaryAmpStore()
        defer { fixture.remove() }
        try fixture.write(#"""
        {"version":1,"sessions":{
          "T-older":{"cwd":"/tmp/other","title":" Older work ","updatedAt":100},
          "T-newer":{"sessionId":"T-newer","cwd":"/tmp/amp/../amp","title":"Ship Amp","updatedAt":200,
            "launchCommand":{"launcher":"amp","executablePath":"/opt/amp/bin/amp","arguments":["/opt/amp/bin/amp","--mode","smart"],"workingDirectory":"/tmp/amp","environment":{},"capturedAt":123,"source":"process"}},
          "not-an-amp-thread":{"updatedAt":300},
          "T-type-drift":{"cwd":42,"updatedAt":400}
        }}
        """#)
        let repository = AmpHookSessionRepository()

        let all = try await repository.snapshots(
            at: fixture.url,
            matching: "",
            workingDirectory: nil,
            offset: 0,
            limit: 10
        )
        #expect(all.map(\.sessionID) == ["T-newer", "T-older"])
        #expect(all.first?.title == "Ship Amp")
        #expect(all.first?.workingDirectory == "/tmp/amp")
        #expect(all.first?.launchCommand?.executablePath == "/opt/amp/bin/amp")

        let boundedPage = try await repository.snapshots(
            at: fixture.url,
            matching: "",
            workingDirectory: nil,
            offset: 1,
            limit: 1
        )
        #expect(boundedPage.map(\.sessionID) == ["T-older"])

        let page = try await repository.snapshots(
            at: fixture.url,
            matching: "ship",
            workingDirectory: "/tmp/amp/",
            offset: 0,
            limit: 1
        )
        #expect(page.map(\.sessionID) == ["T-newer"])
    }

    @Test("the source cache is reused until the modification-time and size fingerprint changes")
    func cacheReuseAndRefresh() async throws {
        let fixture = try TemporaryAmpStore()
        defer { fixture.remove() }
        let first = #"{"version":1,"sessions":{"T-alpha":{"title":"alpha","updatedAt":1}}}"#
        let second = #"{"version":1,"sessions":{"T-bravo":{"title":"bravo","updatedAt":1}}}"#
        #expect(first.utf8.count == second.utf8.count)
        let cachedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try fixture.write(first, modificationDate: cachedDate)
        let repository = AmpHookSessionRepository(sourceCacheCapacity: 1)

        let initial = try await repository.snapshots(
            at: fixture.url,
            matching: "",
            workingDirectory: nil,
            offset: 0,
            limit: 10
        )
        try fixture.write(second, modificationDate: cachedDate)
        let cached = try await repository.snapshots(
            at: fixture.url,
            matching: "",
            workingDirectory: nil,
            offset: 0,
            limit: 10
        )
        try FileManager.default.setAttributes(
            [.modificationDate: cachedDate.addingTimeInterval(10)],
            ofItemAtPath: fixture.url.path
        )
        let refreshed = try await repository.snapshots(
            at: fixture.url,
            matching: "",
            workingDirectory: nil,
            offset: 0,
            limit: 10
        )

        #expect(initial.map(\.sessionID) == ["T-alpha"])
        #expect(cached.map(\.sessionID) == ["T-alpha"])
        #expect(refreshed.map(\.sessionID) == ["T-bravo"])
    }

    @Test("a missing store is empty while malformed history reports an unreadable store")
    func missingAndMalformedStores() async throws {
        let fixture = try TemporaryAmpStore()
        defer { fixture.remove() }
        let repository = AmpHookSessionRepository()

        let missing = try await repository.snapshots(
            at: fixture.url,
            matching: "",
            workingDirectory: nil,
            offset: 0,
            limit: 10
        )
        #expect(missing.isEmpty)

        try fixture.write("{")
        await #expect(throws: AmpHookSessionRepositoryError.unreadableStore) {
            try await repository.snapshots(
                at: fixture.url,
                matching: "",
                workingDirectory: nil,
                offset: 0,
                limit: 10
            )
        }
    }
}

private struct TemporaryAmpStore {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-amp-store-tests-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("amp-hook-sessions.json", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(_ contents: String, modificationDate: Date? = nil) throws {
        try Data(contents.utf8).write(to: url)
        if let modificationDate {
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate],
                ofItemAtPath: url.path
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
