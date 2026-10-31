import CmuxNextFiles
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// A Find result opens the code editor at its line and column: a new editor tab's
/// `cmux.editor.config` carries `reveal: {line, column}` once (the page moves the cursor there
/// after the load); a later config (a reload, an open in the page) starts at the top again.
@MainActor @Suite struct EditorRevealConfigTests {
    private final class Host: FilePageHosting {
        var roots: FileWorkspaceRoots { FileWorkspaceRoots(folders: []) }
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

    @Test func aNewEditorTabsConfigRevealsThePositionOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "editor-reveal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "a.swift")
        try Data("one\ntwo\nthree\n".utf8).write(to: url)
        let provider = FilePageProvider(kind: .editor, file: url, host: Host(), libraries: nil, images: NoImages())
        defer { provider.close() }
        provider.reveal = FilePosition(line: 3, column: 2)
        let context = PageCallContext(page: FilePageKind.editor.namespace)

        let first = try await provider.call(FilePageKind.editor.op("config"), params: .object([:]), context: context)
        #expect(first["reveal"]?["line"]?.intValue == 3)
        #expect(first["reveal"]?["column"]?.intValue == 2)

        let second = try await provider.call(FilePageKind.editor.op("config"), params: .object([:]), context: context)
        #expect(second["reveal"] == nil)
    }

    @Test func theRevealCommandTextIsLineAndColumn() {
        #expect(FilePosition(line: 12, column: 5).pageText == "12:5")
    }
}
