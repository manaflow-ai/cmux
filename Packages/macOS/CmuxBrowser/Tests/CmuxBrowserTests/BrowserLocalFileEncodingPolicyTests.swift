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
        let declaredHTTPURL = directory.appendingPathComponent("declared-http.html")
        try Data("<meta http-equiv=\"content-type\" content=\"text/html; charset=windows-1252\">산책".utf8)
            .write(to: declaredHTTPURL)
        let descriptionURL = directory.appendingPathComponent("description.html")
        try Data("<meta name=\"description\" content=\"charset appears in this description\">산책".utf8)
            .write(to: descriptionURL)
        let commentedDeclarationURL = directory.appendingPathComponent("commented-declaration.html")
        try Data("<!-- <meta charset=\"windows-1252\"> -->산책".utf8).write(to: commentedDeclarationURL)
        let unsupportedDeclarationURL = directory.appendingPathComponent("unsupported-declaration.html")
        try Data("<meta charset=\"unsupported-encoding\">산책".utf8).write(to: unsupportedDeclarationURL)
        let unsupportedHTTPDeclarationURL = directory.appendingPathComponent("unsupported-http-declaration.html")
        try Data("<meta http-equiv=\"content-type\" content=\"text/html; charset=unsupported-encoding\">산책".utf8)
            .write(to: unsupportedHTTPDeclarationURL)

        #expect(await BrowserLocalFileEncodingPolicy.preferredEncodingName(for: utf8URL) == "UTF-8")
        #expect(await BrowserLocalFileEncodingPolicy.preferredEncodingName(for: legacyURL) == nil)
        #expect(await BrowserLocalFileEncodingPolicy.preferredEncodingName(for: declaredURL) == nil)
        #expect(await BrowserLocalFileEncodingPolicy.preferredEncodingName(for: declaredHTTPURL) == nil)
        #expect(await BrowserLocalFileEncodingPolicy.preferredEncodingName(for: descriptionURL) == "UTF-8")
        #expect(await BrowserLocalFileEncodingPolicy.preferredEncodingName(for: commentedDeclarationURL) == "UTF-8")
        #expect(await BrowserLocalFileEncodingPolicy.preferredEncodingName(for: unsupportedDeclarationURL) == "UTF-8")
        #expect(await BrowserLocalFileEncodingPolicy.preferredEncodingName(for: unsupportedHTTPDeclarationURL) == "UTF-8")
        #expect(await BrowserLocalFileEncodingPolicy.preferredEncodingName(for: URL(string: "https://example.com")!) == nil)
    }
}
