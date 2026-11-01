import CmuxNextFiles
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// When the native omnibar shows the file's path above the Markdown page (design section 2), the
/// page's config says `omnibar: true`, so the page's toolbar drops its own file name. Without the
/// bar (the code editor, an older host) the key is absent.
@MainActor @Suite struct MarkdownOmnibarConfigTests {
    private final class Host: FilePageHosting {
        let showsOmnibar: Bool
        init(showsOmnibar: Bool) { self.showsOmnibar = showsOmnibar }
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

    private static func config(showsOmnibar: Bool, kind: FilePageKind = .markdown) async throws -> JSONValue {
        let folder = FileManager.default.temporaryDirectory.appending(path: "md-omni-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: kind == .markdown ? "a.md" : "a.txt")
        try Data("# A\n".utf8).write(to: url)
        let provider = FilePageProvider(kind: kind, file: url, host: Host(showsOmnibar: showsOmnibar), libraries: nil, images: NoImages())
        defer { provider.close() }
        return try await provider.call(kind.op("config"), params: .object([:]), context: PageCallContext(page: kind.namespace))
    }

    @Test func theConfigSaysTheOmnibarShowsThePath() async throws {
        #expect(try await Self.config(showsOmnibar: true)["omnibar"]?.boolValue == true)
    }

    @Test func withoutTheBarTheConfigHasNoOmnibarKey() async throws {
        #expect(try await Self.config(showsOmnibar: false)["omnibar"] == nil)
        #expect(try await Self.config(showsOmnibar: true, kind: .editor)["omnibar"] == nil)
    }
}
