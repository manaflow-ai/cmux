import Darwin
import Foundation
import Testing
@testable import CmuxBrowser

@Suite("CmuxDiffViewerSessionPreparer", .serialized)
struct CmuxDiffViewerSessionPreparerTests {
    @Test
    func rejectsOversizedAllowlistBeforeInspectingEntries() throws {
        let rootURL = try makeRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let preparer = CmuxDiffViewerSessionPreparer(
            trustedRootURL: rootURL,
            maximumRegisteredFiles: 2
        )
        let files = (0..<3).map { index in
            CmuxDiffViewerRegisteredFile(
                requestPath: "/asset-\(index).html",
                fileURL: rootURL.appendingPathComponent("missing-\(index).html"),
                mimeType: "text/html"
            )
        }

        #expect(throws: CmuxDiffViewerSessionError.allowlistTooLarge) {
            _ = try preparer.prepare(token: UUID().uuidString, files: files)
        }
    }

    @Test
    func boundsManifestBytesBeforeDecoding() throws {
        let rootURL = try makeRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let token = UUID().uuidString
        let manifestURL = rootURL.appendingPathComponent(".manifest-\(token).json")
        try Data(repeating: 0x20, count: 65).write(to: manifestURL)
        let preparer = CmuxDiffViewerSessionPreparer(
            trustedRootURL: rootURL,
            maximumManifestBytes: 64
        )

        #expect(throws: CmuxDiffViewerSessionError.manifestTooLarge) {
            _ = try preparer.prepareFromManifest(token: token)
        }
    }

    @Test
    func rejectsOversizedManifestBeforeInspectingEntries() throws {
        let rootURL = try makeRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let token = UUID().uuidString
        let manifestURL = rootURL.appendingPathComponent(".manifest-\(token).json")
        let files = (0..<3).map { index in
            [
                "request_path": "/asset-\(index).html",
                "file_path": rootURL.appendingPathComponent("missing-\(index).html").path,
                "mime_type": "text/html",
            ]
        }
        try JSONSerialization.data(withJSONObject: [
            "token": token,
            "files": files,
        ]).write(to: manifestURL)
        let preparer = CmuxDiffViewerSessionPreparer(
            trustedRootURL: rootURL,
            maximumRegisteredFiles: 2
        )

        #expect(throws: CmuxDiffViewerSessionError.allowlistTooLarge) {
            _ = try preparer.prepareFromManifest(token: token)
        }
    }

    @Test
    func tokenSyntaxIsASCIIAndByteBounded() {
        #expect(CmuxDiffViewerSessionPreparer.isValidToken("abcdefghijklmnop"))
        #expect(CmuxDiffViewerSessionPreparer.isValidToken("ABCDEF0123456789-token"))
        #expect(!CmuxDiffViewerSessionPreparer.isValidToken(String(repeating: "é", count: 16)))
        #expect(!CmuxDiffViewerSessionPreparer.isValidToken(String(repeating: "a", count: 81)))
    }

    @Test
    func leaseOpenDoesNotFollowFinalSymlink() throws {
        let rootURL = try makeRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let token = UUID().uuidString
        let entryURL = rootURL.appendingPathComponent("index.html")
        try Data("<!doctype html>".utf8).write(to: entryURL)
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-lease-target-\(UUID().uuidString)")
        try Data("unchanged".utf8).write(to: outsideURL)
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        let leaseURL = rootURL.appendingPathComponent(".session-lease-\(token).lock")
        try #require(symlink(outsideURL.path, leaseURL.path) == 0)

        let preparer = CmuxDiffViewerSessionPreparer(trustedRootURL: rootURL)
        #expect(throws: POSIXError(.EWOULDBLOCK)) {
            _ = try preparer.prepare(
                token: token,
                files: [
                    CmuxDiffViewerRegisteredFile(
                        requestPath: "/index.html",
                        fileURL: entryURL,
                        mimeType: "text/html"
                    ),
                ]
            )
        }
        #expect(try Data(contentsOf: outsideURL) == Data("unchanged".utf8))
    }

    private func makeRoot() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-diff-viewer-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return rootURL
    }
}
