@testable import CmuxNextApp
import AppKit
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The file pages' path grants (React UIs lead review of S6/S7, coordinator rule): a page opens
/// only a path the user granted (the tab's document, a chooseFile result, a recents entry); a
/// link inside a granted document's folder opens without asking; any other link asks with a
/// native sheet that names the resolved path, only after a real user gesture, one sheet at a time.
/// Symlinks are resolved before every check. Roots are only folders the user chose.
@MainActor
@Suite(.serialized)
struct FilePageGrantTests {
    typealias Host = FilePageProviderTests.Host

    static func code(_ body: () async throws -> Void) async -> String? { await FilePageProviderTests.code(body) }

    /// A home with `.ssh/id_rsa`, and a project folder with README.md, other.md, a symlink that
    /// points at `.ssh` and one at the key.
    static func world() throws -> (FilePageProvider, Host, project: URL, key: URL) {
        let (provider, host, project, _) = try FilePageProviderTests.world(.markdown)
        let home = try FileDocumentTests.folder()
        try FileManager.default.createDirectory(at: home.appending(path: ".ssh"), withIntermediateDirectories: true)
        let key = home.appending(path: ".ssh/id_rsa")
        try Data("PRIVATE KEY".utf8).write(to: key)
        try FileManager.default.createSymbolicLink(at: project.appending(path: "ssh"), withDestinationURL: home.appending(path: ".ssh"))
        try FileManager.default.createSymbolicLink(at: project.appending(path: "key.md"), withDestinationURL: key)
        return (provider, host, project, key)
    }

    static func open(_ provider: FilePageProvider, _ path: String) async throws -> JSONValue {
        try await FilePageProviderTests.call(provider, "cmux.markdown.open", ["path": .string(path)])
    }

    static func link(_ provider: FilePageProvider, from: URL, href: String, target: String) async throws {
        _ = try await FilePageProviderTests.call(provider, "cmux.markdown.openLink",
                                                 ["path": .string(from.path), "href": .string(href), "kind": "file", "target": .string(target)])
    }

    @Test func aPageCannotOpenAPathTheUserDidNotGrant() async throws {
        let (provider, host, project, key) = try Self.world()
        #expect(await Self.code { _ = try await Self.open(provider, key.path) } == "cmux.markdown.forbidden")
        // A symlink inside the project that points at the key is the key.
        #expect(await Self.code { _ = try await Self.open(provider, project.appending(path: "key.md").path) } == "cmux.markdown.forbidden")
        #expect(host.recorded.isEmpty)
        // The tab's own document stays open to it.
        _ = try await Self.open(provider, project.appending(path: "README.md").path)
    }

    @Test func aChooseFileResultAndARecentEntryAreGranted() async throws {
        let (provider, host, project, _) = try Self.world()
        let other = project.appending(path: "other.md")
        host.chosen = other
        _ = try await FilePageProviderTests.call(provider, "cmux.markdown.chooseFile")
        #expect(try await Self.open(provider, other.path)["text"]?.stringValue == "# Other\n")
        let (fresh, freshHost, freshProject, _) = try Self.world()
        let recent = freshProject.appending(path: "other.md")
        freshHost.recentPaths = [recent.path]
        #expect(try await Self.open(fresh, recent.path)["text"]?.stringValue == "# Other\n")
    }

    @Test func aSiblingLinkOpensWithoutAsking() async throws {
        let (provider, host, project, _) = try Self.world()
        try await Self.link(provider, from: project.appending(path: "README.md"), href: "main.swift",
                            target: project.appending(path: "main.swift").path)
        #expect(host.files == [project.appending(path: "main.swift")])
        #expect(host.confirmations.isEmpty)
    }

    @Test func aLinkOutsideTheDocumentsFolderAsksWithItsResolvedPath() async throws {
        let (provider, host, project, key) = try Self.world()
        let readme = project.appending(path: "README.md")
        host.confirmAnswer = false
        #expect(await Self.code {
            try await Self.link(provider, from: readme, href: "../../.ssh/id_rsa", target: key.path)
        } == "cmux.page.cancelled")
        #expect(host.files.isEmpty)
        // A symlink in the folder that points outside asks too, naming where it points.
        #expect(await Self.code {
            try await Self.link(provider, from: readme, href: "ssh/id_rsa", target: project.appending(path: "ssh/id_rsa").path)
        } == "cmux.page.cancelled")
        #expect(host.confirmations.last == key.standardizedFileURL.resolvingSymlinksInPath())
        host.confirmAnswer = true
        try await Self.link(provider, from: readme, href: "ssh/id_rsa", target: project.appending(path: "ssh/id_rsa").path)
        #expect(host.files == [key.standardizedFileURL.resolvingSymlinksInPath()])
    }

    /// The sheet shows only for a call backed by a real gesture (`PageCallContext.userGesture`, the
    /// router's 1 s window), once per gesture (the event's uptime), one sheet at a time.
    @Test func aConfirmationNeedsAGestureUsesItOnceAndShowsOneSheetAtATime() async throws {
        final class Presenter: PageConfirmationPresenter {
            var shown: [PageConfirmation] = []
            var nested: (() async -> Bool)?
            var nestedAnswer: Bool?
            func confirm(_ confirmation: PageConfirmation, anchor: NSView?) async -> Bool {
                shown.append(confirmation)
                if let nested { nestedAnswer = await nested() }
                return true
            }
        }
        let presenter = Presenter()
        let gate = FileOpenConfirmation(presenter: presenter)
        let target = URL(fileURLWithPath: "/Users/ada/.ssh/id_rsa")
        #expect(await gate.confirm(target, userGesture: false, gestureEvent: 10, anchor: nil) == false, "no gesture: no sheet")
        #expect(await gate.confirm(target, userGesture: true, gestureEvent: nil, anchor: nil) == false, "no event: no sheet")
        #expect(presenter.shown.isEmpty)
        presenter.nested = { await gate.confirm(target, userGesture: true, gestureEvent: 11, anchor: nil) }
        #expect(await gate.confirm(target, userGesture: true, gestureEvent: 10, anchor: nil))
        #expect(presenter.shown.count == 1)
        #expect(presenter.nestedAnswer == false, "a second sheet while one shows is refused")
        #expect(presenter.shown.first?.name.contains("/Users/ada/.ssh/id_rsa") == true)
        presenter.nested = nil
        // The same gesture opens no second sheet; a new gesture does.
        #expect(await gate.confirm(target, userGesture: true, gestureEvent: 10, anchor: nil) == false)
        #expect(await gate.confirm(target, userGesture: true, gestureEvent: 12, anchor: nil))
        #expect(presenter.shown.count == 2)
    }

    /// The provider hands the call's gesture to the host's sheet.
    @Test func anOutsideLinkPassesItsGestureToTheSheet() async throws {
        let (provider, host, project, key) = try Self.world()
        host.confirmAnswer = false
        _ = await Self.code {
            _ = try await FilePageProviderTests.call(provider, "cmux.markdown.openLink",
                                                     ["path": .string(project.appending(path: "README.md").path), "href": "x", "kind": "file",
                                                      "target": .string(key.path)], userGesture: true)
        }
        #expect(host.confirmGestures == [true])
    }

    @Test func listFilesResolvesSymlinksBeforeTheFolderCheck() async throws {
        let (provider, _, project, _) = try Self.world()
        let listed = try await FilePageProviderTests.call(provider, "cmux.markdown.listFiles",
                                                         ["from": .string(project.appending(path: "README.md").path), "prefix": "ssh/"])
        #expect(listed["entries"]?.arrayValue?.isEmpty == true)
    }

    /// Roots hold only folders the user chose: never home, never a terminal folder the host infers.
    @Test func rootsAreOnlyFoldersTheUserChose() throws {
        let home = try FileDocumentTests.folder()
        let chosen = home.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let roots = FileWorkspaceRoots(folders: [home.path, chosen.path], home: home.path)
        #expect(roots.paths == [chosen.path])
        #expect(!roots.contains(home.appending(path: "notes.md").path))
        let services = ActionBindingCoverageTests.boundServices()
        // The app's roots come from the user's choices only (no terminal working directories).
        #expect(services.editorPages.roots.paths == FilePageService.userChosenRoots(services).paths)
        #expect(!services.editorPages.roots.contains(NSHomeDirectory() + "/notes.md"))
    }
}
