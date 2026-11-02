import CmuxNextFiles
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Every markdown viewer is read-write (user 2026-10-18): a markdown file that `cmux open`, an
/// agent or a link opened (not the user's own Open File...) opens editable and saves, in any
/// workspace, Home included, with no `files.roots` folder. Home's folder (the home directory) is
/// never a root, which is what made these viewers read only. Only a real reason keeps one read
/// only: a file it cannot write, or a chat transcript the host opens read only. The code editor
/// keeps its rule (writable only when the user chose the file or it is inside a root).
@MainActor @Suite struct MarkdownViewerWritableTests {
    private final class Host: FilePageHosting {
        var roots: FileWorkspaceRoots
        init(roots: FileWorkspaceRoots) { self.roots = roots }
        var remoteImages: Bool { false }
        func recents() -> JSONValue { ["items": []] }
        func record(_ url: URL) {}
        func chooseFile(start: URL?) async -> URL? { nil }
        func look() -> JSONValue { .object([:]) }
        func listenLook(_ onLook: @escaping @MainActor (JSONValue) -> Void) -> () -> Void { {} }
        func setPreference(key: String, value: JSONValue, by writer: SettingWriter) async throws {}
        func opened(_ url: URL) {}
        func openExternal(_ url: URL) {}
        func openFile(_ url: URL) {}
        func openAppLink(_ url: URL) -> Bool { false }
        func isRecent(_ path: String) -> Bool { false }
        func confirmOpen(_ url: URL, userGesture: Bool) async -> Bool { false }
        func edited(_ url: URL, text: String, baseHash: String?, writable: Bool) -> RecoveryDraftAcceptance { .kept }
        func saved(_ url: URL, hash: String) {}
    }

    private final class NoImages: RemoteImageFetching {
        func fetch(_ url: URL) async -> PageResource? { nil }
    }

    /// A temporary folder with `name` holding `text`, removed by the caller.
    private static func file(_ name: String, _ text: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "md-rw-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url.resolvingSymlinksInPath()
    }

    /// The tab's provider as `cmux open` from the Home workspace makes it: not the user's choice,
    /// and the only folder offered as a root is home itself (never a root).
    private static func provider(_ kind: FilePageKind, _ url: URL, userChose: Bool = false, readOnly: Bool = false) -> FilePageProvider {
        let host = Host(roots: FileWorkspaceRoots(folders: [NSHomeDirectory()]))
        return FilePageProvider(kind: kind, file: url, userChose: userChose, readOnly: readOnly, host: host, libraries: nil, images: NoImages())
    }

    private static func call(_ provider: FilePageProvider, _ name: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        try await provider.call("\(provider.kind.namespace).\(name)", params: params, context: PageCallContext(page: provider.kind.namespace))
    }

    @Test func aMarkdownFileOpenedFromTheHomeWorkspaceIsEditableAndSaves() async throws {
        let url = try Self.file("notes.md", "# Notes\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = Self.provider(.markdown, url)
        defer { provider.close() }
        let config = try await Self.call(provider, "config")
        #expect(config["readOnly"] == nil)
        #expect(config["readOnlyReason"] == nil)
        #expect(provider.isWritable)
        let hash = try #require(config["hash"]?.stringValue)
        let saved = try await Self.call(provider, "save", ["path": .string(url.path), "text": "# Notes\nedited\n", "baseHash": .string(hash)])
        #expect(saved["hash"]?.stringValue != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Notes\nedited\n")
    }

    @Test func theCodeEditorKeepsItsRootRule() async throws {
        let url = try Self.file("notes.txt", "text\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = Self.provider(.editor, url)
        defer { provider.close() }
        let config = try await Self.call(provider, "config")
        #expect(config["readOnly"] == true)
        #expect(config["readOnlyReason"]?.stringValue == "outside")
    }

    @Test func aFileThatCannotBeWrittenSaysWhy() async throws {
        let url = try Self.file("locked.md", "locked\n")
        defer {
            chmod(url.path, 0o644)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        chmod(url.path, 0o444)
        let provider = Self.provider(.markdown, url)
        defer { provider.close() }
        let config = try await Self.call(provider, "config")
        #expect(config["readOnly"] == true)
        #expect(config["readOnlyReason"]?.stringValue == "permission")
    }

    @Test func aChatTranscriptStaysReadOnlyAndRefusesASave() async throws {
        let url = try Self.file("chat.md", "transcript\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = Self.provider(.markdown, url, readOnly: true)
        defer { provider.close() }
        let config = try await Self.call(provider, "config")
        #expect(config["readOnly"] == true)
        #expect(config["readOnlyReason"]?.stringValue == "transcript")
        let hash = try #require(config["hash"]?.stringValue)
        await #expect(throws: PageError.self) {
            _ = try await Self.call(provider, "save", ["path": .string(url.path), "text": "changed\n", "baseHash": .string(hash)])
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "transcript\n")
    }
}
