import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDiff

/// Open the file from the diff (D4): the page's file name, its menu rows and a Cmd-click on a line
/// call `cmux.diff.openFile {path, line?, where?}`. The path is relative to the tab's repository
/// and must stay inside it after symlinks, out of `.git`; the file must exist; each open spends one
/// real click or key. A tab shows the source in the code editor, never a rendered web page.
@MainActor
@Suite(.serialized)
struct DiffOpenFileTests {
    final class RecordingHost: DiffTabHosting {
        var opened: [(URL, Int?, DiffFileTarget)] = []
        var answer = true

        func repository(at folder: URL) async -> DiffRepository? { nil }
        func prepare(_ repository: DiffRepository, source: DiffOpenSource) -> Task<DiffTabReady, any Error> {
            Task { throw DiffTabFailure(title: "", message: "") }
        }
        func recents() async -> JSONValue { ["items": []] }
        func chooseFolder(start: URL?) async -> URL? { nil }
        func opened(_ repository: DiffRepository, source: DiffOpenSource) {}
        func openFile(_ file: URL, line: Int?, target: DiffFileTarget) -> Bool {
            opened.append((file, line, target))
            return answer
        }
    }

    /// A folder standing for the repository: `src/upload.ts`, a folder `src/lib`, and links that
    /// point inside and outside it.
    static func makeRepository() throws -> (repository: URL, outside: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "diff-open-\(UUID().uuidString)")
        let repository = base.appending(path: "repo")
        let outside = base.appending(path: "secret.txt")
        try FileManager.default.createDirectory(at: repository.appending(path: "src/lib"), withIntermediateDirectories: true)
        try Data("let a = 1\n".utf8).write(to: repository.appending(path: "src/upload.ts"))
        try Data("token\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: repository.appending(path: "src/escape.txt"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: repository.appending(path: "src/alias.ts"),
                                                   withDestinationURL: repository.appending(path: "src/upload.ts"))
        // A sibling folder whose name starts with the repository's, a link to it, and a link to the
        // folder above the repository: the paths pass the request check, so only the containment
        // check after symlinks stops them.
        let sibling = base.appending(path: "repo-other")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: sibling.appending(path: "a.ts"))
        try FileManager.default.createSymbolicLink(at: repository.appending(path: "src/sib"), withDestinationURL: sibling)
        try FileManager.default.createSymbolicLink(at: repository.appending(path: "src/out"), withDestinationURL: base)
        // git's own folder, and a link into it.
        try FileManager.default.createDirectory(at: repository.appending(path: ".git"), withIntermediateDirectories: true)
        try Data("[core]\n".utf8).write(to: repository.appending(path: ".git/config"))
        try FileManager.default.createSymbolicLink(at: repository.appending(path: "src/gitconfig"),
                                                   withDestinationURL: repository.appending(path: ".git/config"))
        return (repository, outside)
    }

    @Test func aRequestNamesAFileOfTheRepositoryAndALine() throws {
        let request = try DiffFileOpenRequest(["path": "src/upload.ts", "line": 12, "where": "editor"])
        #expect(request == DiffFileOpenRequest(path: "src/upload.ts", line: 12, target: .editor))
        #expect(try DiffFileOpenRequest(["path": "README.md"]) == DiffFileOpenRequest(path: "README.md"))
        #expect(try DiffFileOpenRequest(["path": "a.ts", "line": .null, "where": .null]) == DiffFileOpenRequest(path: "a.ts"))

        for path in ["", "/etc/passwd", "~/notes.md", "../outside.ts", "src/../../outside.ts", "./src/a.ts",
                     "src//a.ts", "src/a.ts/", "src/\u{0}a.ts", String(repeating: "a", count: 4097),
                     ".git/config", "sub/.git/hooks/pre-commit", ".GIT/config"] {
            #expect(throws: PageError.self, "path \(path.prefix(40))") { try DiffFileOpenRequest(["path": .string(path)]) }
        }
        #expect(throws: PageError.self) { try DiffFileOpenRequest(["path": 7]) }
        for line: JSONValue in [0, -3, 1.5, 10_000_001, "12"] {
            #expect(throws: PageError.self, "line \(line)") { try DiffFileOpenRequest(["path": "a.ts", "line": line]) }
        }
        #expect(throws: PageError.self) { try DiffFileOpenRequest(["path": "a.ts", "where": "browser"]) }
    }

    @Test func onlyAnExistingFileInsideTheRepositoryResolves() async throws {
        let (repository, outside) = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: repository.deletingLastPathComponent()) }
        let real = repository.appending(path: "src/upload.ts").resolvingSymlinksInPath()

        #expect(await DiffPageProvider.repositoryFile("src/upload.ts", in: repository.path) == real)
        // A link inside the repository to a file inside it opens that file.
        #expect(await DiffPageProvider.repositoryFile("src/alias.ts", in: repository.path) == real)
        // A link that leaves the repository, a folder, a missing (deleted) file and a climb open nothing.
        #expect(await DiffPageProvider.repositoryFile("src/escape.txt", in: repository.path) == nil)
        #expect(await DiffPageProvider.repositoryFile("src/lib", in: repository.path) == nil)
        #expect(await DiffPageProvider.repositoryFile("src/gone.ts", in: repository.path) == nil)
        #expect(await DiffPageProvider.repositoryFile("../secret.txt", in: repository.path) == nil)
        #expect(await DiffPageProvider.repositoryFile(outside.path, in: repository.path) == nil)
        // These pass the request check; the containment check after symlinks refuses them. A
        // check without the trailing "/" would let `repo-other` through.
        for path in ["src/sib/a.ts", "src/out/secret.txt", "src/out/repo-other/a.ts", "src/gitconfig"] {
            #expect(DiffFileOpenRequest.isRepositoryPath(path), "\(path)")
            #expect(await DiffPageProvider.repositoryFile(path, in: repository.path) == nil, "\(path)")
        }
        // The same root reached through the link above it still opens its own file.
        #expect(await DiffPageProvider.repositoryFile("src/upload.ts", in: repository.appending(path: "src/out/repo").path) == real)
    }

    @Test func aTabShowsTheSourceNeverARenderedPage() {
        let open = { (name: String, line: Int?) in DiffPageService.filePage(for: URL(fileURLWithPath: "/r/\(name)"), line: line) }
        for name in ["index.html", "page.htm", "logo.svg", "app.xhtml", "main.ts", "Makefile", "run.command"] {
            #expect(open(name, nil) == .editor, "\(name)")
            #expect(open(name, 40) == .editor, "\(name)")
        }
        // Markdown opens its page, or the editor when a line was asked for (the page has no lines).
        #expect(open("README.md", nil) == .viewer)
        #expect(open("README.md", 120) == .editor)
        // Images, PDFs and media keep the preview, which runs nothing.
        for name in ["shot.png", "spec.pdf", "clip.mp4"] { #expect(open(name, 3) == .viewer, "\(name)") }
    }

    @Test func aDiffTabOpensItsOwnFilesOnAClick() async throws {
        let (repository, _) = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: repository.deletingLastPathComponent()) }
        let sessions = repository.deletingLastPathComponent().appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let grant = try DiffSessionGrant.create(root: sessions, repository: repository.path)
        defer { grant.remove() }
        let host = RecordingHost()
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: nil, languages: nil, host: host)
        // A click at uptime `at` seconds; each open needs a newer one.
        let click = { (at: TimeInterval) in PageCallContext(page: "cmux.diff", userGesture: true, gestureEvent: at) }
        let real = repository.appending(path: "src/upload.ts").resolvingSymlinksInPath()

        // The page learns the op from its config.
        let config = try await provider.call("cmux.diff.config", params: [:], context: PageCallContext(page: "cmux.diff"))
        #expect(config["ops"]?.arrayValue?.contains("cmux.diff.openFile") == true)

        _ = try await provider.call("cmux.diff.openFile", params: ["path": "src/upload.ts", "line": 4], context: click(1))
        _ = try await provider.call("cmux.diff.openFile", params: ["path": "src/upload.ts", "where": "finder"], context: click(2))
        #expect(host.opened.map(\.0) == [real, real])
        #expect(host.opened.map(\.1) == [4, nil])
        #expect(host.opened.map(\.2) == [.tab, .finder])

        // No click or key in the page: nothing opens.
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.openFile", params: ["path": "src/upload.ts"], context: PageCallContext(page: "cmux.diff"))
        }
        // A file outside the repository, or one the diff deleted: refused, nothing opens.
        for (index, path) in ["src/escape.txt", "src/gone.ts", "/etc/hosts", ".git/config", "src/gitconfig"].enumerated() {
            await #expect(throws: PageError.self, "path \(path)") {
                _ = try await provider.call("cmux.diff.openFile", params: ["path": .string(path)], context: click(10 + Double(index)))
            }
        }
        #expect(host.opened.count == 2)
        // One gesture opens one file: a second call on the same click is refused.
        let once = click(20)
        _ = try await provider.call("cmux.diff.openFile", params: ["path": "src/upload.ts"], context: once)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.openFile", params: ["path": "src/upload.ts"], context: once)
        }
        #expect(host.opened.count == 3)
        // The host opened nothing (no pane): the page hears it.
        host.answer = false
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.openFile", params: ["path": "src/upload.ts"], context: click(21))
        }
        await provider.close()
    }
}
