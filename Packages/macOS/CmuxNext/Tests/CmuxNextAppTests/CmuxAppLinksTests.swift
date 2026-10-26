import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing

/// A cmux link clicked in rendered Markdown (a Markdown file page, Home, an agent chat) opens in
/// this app when it names a workspace, pane, tab or chat, in the plain `cmux` scheme the Chief
/// and its documents write or in this build's own scheme; nothing else is an app link.
struct CmuxAppLinksTests {
    private let ws = "ws_0123456789abcdef0123456789abcdef"
    private let scheme = "cmux-dev-mytag"

    private func link(_ text: String, chiefHost: String? = "chief:2e448bc2") -> DeepLink? {
        CmuxAppLinks.link(for: URL(string: text)!, linkScheme: scheme, chiefHost: chiefHost)
    }

    @Test func aWorkspaceLinkInTheChiefsSchemeOrThisBuildsOpensThatWorkspace() {
        #expect(link("cmux://workspace/\(ws)")?.target == .workspace(ws))
        #expect(link("\(scheme)://workspace/\(ws)")?.target == .workspace(ws))
        #expect(link("cmux://workspace/\(ws)")?.url(scheme: scheme)?.absoluteString == "\(scheme)://workspace/\(ws)")
    }

    @Test func paneTabAndSessionLinksOpenToo() {
        #expect(link("cmux://pane/pane_0123456789abcdef0123456789abcdef")?.target == .pane("pane_0123456789abcdef0123456789abcdef"))
        #expect(link("cmux://tab/tab_0123456789abcdef0123456789abcdef")?.target == .tab("tab_0123456789abcdef0123456789abcdef"))
        #expect(link("cmux://session/01a12408-f0a2")?.target == .session("01a12408-f0a2", turn: nil))
    }

    @Test func aChiefSubagentLinkOpensOnlyForThisAppsOwnChief() {
        let text = "cmux://chief/2e448bc2/session/01a12408-f0a2"
        #expect(link(text)?.target == .chiefSession(home: "2e448bc2", session: "01a12408-f0a2"))
        #expect(link(text, chiefHost: "chief:00000000") == nil)
        #expect(link(text, chiefHost: nil) == nil)
    }

    @Test(arguments: [
        "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "vbscript:x", "ssh://host/x",
        "https://cmux.dev/workspace/ws_0123456789abcdef0123456789abcdef",
        "cmux://workspace/1", "cmux://workspace/ws_short", "other-app://workspace/ws_0123456789abcdef0123456789abcdef",
        "cmux://auth-callback",
    ])
    func everythingElseIsNotAnAppLink(_ text: String) {
        #expect(link(text) == nil)
    }

    #if DEBUG
    /// A clicked path link checks whether it is a folder on the files lane, never on the main thread: the
    /// click's turn returns at once (p02-threads-006). The table is the test's own, so a check on the main
    /// thread shows as a site.
    @MainActor @Test func aPathLinksFolderCheckRunsOnTheFilesLane() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "app-link-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "notes.md")
        try Data("# notes\n".utf8).write(to: file)
        let work = BackgroundWork(label: "test.app-links")

        let table = BlockingViolationTable(mode: .record)
        let answers = await BlockingViolationTable.$scoped.withValue(table) { () async -> [Bool] in
            var answers: [Bool] = []
            for path in [folder.path, file.path, folder.path + "/missing"] {
                answers.append(await CmuxAppLinks.isFolder(path, on: work))
            }
            return answers
        }
        await table.flush()

        #expect(table.sites.isEmpty, "a path link checked the disk on the main thread: \(table.sites)")
        #expect(answers == [true, false, false])
    }
    #endif
}
