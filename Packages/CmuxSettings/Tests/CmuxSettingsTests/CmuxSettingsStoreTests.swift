import XCTest
@testable import CmuxSettings

final class CmuxSettingsStoreTests: XCTestCase {
    func testWriteAndReadPrimarySnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-\(UUID().uuidString)", isDirectory: true)
        let primaryURL = directory.appendingPathComponent("cmux.json", isDirectory: false)
        let store = CmuxSettingsStore(primaryURL: primaryURL, fallbackURLs: [])

        try await store.writePrimaryContents("{\"schemaVersion\":1}")
        let snapshot = try await store.readPrimarySnapshot()

        XCTAssertEqual(snapshot.url, primaryURL)
        XCTAssertEqual(snapshot.contents, "{\"schemaVersion\":1}")
    }

    func testActiveSnapshotFallsBackWhenPrimaryIsMissing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let primaryURL = directory.appendingPathComponent("cmux.json", isDirectory: false)
        let fallbackURL = directory.appendingPathComponent("settings.json", isDirectory: false)
        try "{\"legacy\":true}".write(to: fallbackURL, atomically: true, encoding: .utf8)

        let store = CmuxSettingsStore(primaryURL: primaryURL, fallbackURLs: [fallbackURL])
        let snapshot = try await store.readActiveSnapshot()

        XCTAssertEqual(snapshot.url, fallbackURL)
        XCTAssertEqual(snapshot.contents, "{\"legacy\":true}")
    }
}
