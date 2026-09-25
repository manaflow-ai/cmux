import Foundation
import Testing
@testable import CmuxBrowser

@Suite
struct BrowserLocalFileEncodingPolicyTests {
    @Test func classifiesUTF8TextAndRejectsLegacyOrDeclaredBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let utf8URL = directory.appendingPathComponent("notes.md")
        try Data("# 산책의 즐거움".utf8).write(to: utf8URL)
        let legacyURL = directory.appendingPathComponent("legacy.txt")
        try Data([0xB0, 0xA1]).write(to: legacyURL)
        let declaredURL = directory.appendingPathComponent("declared.html")
        try Data("<meta charset=\"windows-1252\">산책".utf8).write(to: declaredURL)

        #expect(await BrowserLocalFileEncodingPolicy.preferredEncodingName(for: utf8URL) == "UTF-8")
        #expect(await BrowserLocalFileEncodingPolicy.preferredEncodingName(for: legacyURL) == nil)
        #expect(await BrowserLocalFileEncodingPolicy.preferredEncodingName(for: declaredURL) == nil)
        #expect(await BrowserLocalFileEncodingPolicy.preferredEncodingName(for: URL(string: "https://example.com")!) == nil)
    }
}
