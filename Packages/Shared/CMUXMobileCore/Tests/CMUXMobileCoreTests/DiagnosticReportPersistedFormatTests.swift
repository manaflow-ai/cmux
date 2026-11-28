import Foundation
import Testing
@testable import CMUXMobileCore

/// Loads every persisted-formats/diagnostic-report/v*.json fixture (the archive file itself) through
/// DiagnosticReportArchive, as this build and with a newer build's additions
/// (persisted-formats/README-ios-formats.md).
@Suite struct DiagnosticReportPersistedFormatTests {
    @Test func diagnosticReportFixturesLoad() throws {
        let directory = try Self.fixtureDirectory()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("v") && $0.hasSuffix(".json") }
            .sorted()
        #expect(files.contains("v\(DiagnosticReport.currentSchemaVersion).json"))
        for file in files {
            let data = try Data(contentsOf: directory.appendingPathComponent(file))
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "\(file): object")
            try check(data, expected: object, label: file)

            // A newer build's file: a higher schemaVersion and a key this build does not know.
            var newer = object
            newer["schemaVersion"] = ((object["schemaVersion"] as? Int) ?? 0) + 1
            newer["futureField"] = ["kept": true]
            try check(try JSONSerialization.data(withJSONObject: newer), expected: object, label: "\(file) (newer build)")
        }
    }

    private func check(_ data: Data, expected: [String: Any], label: String) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxdiag-fixture-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let archive = DiagnosticReportArchive(fileURL: url)
        let report = try #require(archive.load(), "\(label): loads")
        #expect(report.role.rawValue == expected["role"] as? Int, "\(label): role")
        #expect(report.buildStamp == expected["buildStamp"] as? String, "\(label): buildStamp")
        #expect(report.anchorMonotonicNanos == (expected["anchorMonotonicNanos"] as? Int).map(UInt64.init), "\(label): anchor")
        let events = try #require(expected["events"] as? [[String: Any]], "\(label): events")
        #expect(report.events.map { Int($0.code.rawValue) } == events.compactMap { $0["code"] as? Int }, "\(label): codes")
        #expect(report.events.map(\.tNanos) == events.compactMap { ($0["tNanos"] as? Int).map(UInt64.init) }, "\(label): tNanos")

        // This build writes back what it read, and reads that again.
        archive.save(report)
        let again = try #require(archive.load(), "\(label): reloads")
        #expect(again.events == report.events, "\(label): events round trip")
    }

    /// The repo's persisted-formats/diagnostic-report, found from this file's path.
    static func fixtureDirectory(filePath: String = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let formats = directory.appendingPathComponent("persisted-formats")
            if FileManager.default.fileExists(atPath: formats.appendingPathComponent("formats.toml").path) {
                return formats.appendingPathComponent("diagnostic-report")
            }
            directory = directory.deletingLastPathComponent()
        }
        throw FixtureError.notFound(filePath)
    }

    enum FixtureError: Error {
        case notFound(String)
    }
}
