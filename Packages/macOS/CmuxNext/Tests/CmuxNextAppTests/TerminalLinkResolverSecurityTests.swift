import Foundation
import Testing
@testable import CmuxNextApp
import struct CmuxNextBrowser.TerminalLinkResolver
import enum CmuxNextBrowser.TerminalLinkTarget

@Suite("Terminal link security")
struct TerminalLinkResolverSecurityTests {
    @Test(arguments: [
        "javascript:alert(1)",
        "ssh://host.example/",
        "cmux://settings",
        "mailto:attacker@example.com",
        "data:text/html,payload",
        "ftp://host.example/file",
        "https://user:password@example.com/",
        "https://exa mple.com/",
        "https://example.com/\u{202E}txt",
        "https://example.com/%E2%80%AEtxt",
        "example.com/%E2%80%AEtxt",
    ])
    func rejectsSchemesAndWebAddressesOutsideTheTerminalAllowlist(_ text: String) {
        #expect(TerminalLinkResolver().resolve(text, cwd: nil) == nil)
    }

    @Test(arguments: ["https://example.com/path", "http://localhost:3000/"])
    func acceptsAllowedWebLinks(_ text: String) throws {
        guard case .url(let url)? = TerminalLinkResolver().resolve(text, cwd: nil) else {
            Issue.record("expected an allowed web URL")
            return
        }
        #expect(url.absoluteString == text)
    }

    @Test func acceptsAHostlessLocalFileButRejectsRemoteFileSources() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "terminal-link-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "report draft.txt")
        try Data("report".utf8).write(to: file)

        guard case .file(let local, isDirectory: false)? = TerminalLinkResolver().resolve(file.absoluteString, cwd: nil) else {
            Issue.record("expected the local file URL")
            return
        }
        #expect(local.path == file.path)
        #expect(TerminalLinkResolver().resolve(file.path, cwd: nil) == .file(file, isDirectory: false))
        #expect(TerminalLinkResolver().resolve(file.absoluteString, cwd: nil, allowsLocalFiles: false) == nil)

        var foreign = URLComponents()
        foreign.scheme = "file"
        foreign.host = "remote.example"
        foreign.path = file.path
        #expect(TerminalLinkResolver().resolve(try #require(foreign.url).absoluteString, cwd: nil) == nil)
        #expect(TerminalLinkResolver().resolve("report draft.txt", cwd: try #require(foreign.url).deletingLastPathComponent().absoluteString) == nil)
    }
}
