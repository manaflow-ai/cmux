import CmuxNextFiles
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// A markdown document gets no remote-image resource URL by default. A real click grants only the
/// current document's unguessable resource prefix; the host still fetches the exact URL through
/// `RemoteImageFetching` (production: `GuardedRemoteImages`).
@MainActor @Suite struct MarkdownRemoteImageApprovalTests {
    private final class Host: FilePageHosting {
        var roots: FileWorkspaceRoots { FileWorkspaceRoots(folders: []) }
        var remoteImages = false
        func recents() -> JSONValue { ["items": []] }
        func record(_: URL) {}
        func chooseFile(start _: URL?) async -> URL? { nil }
        func look() -> JSONValue { .object([:]) }
        func listenLook(_: @escaping @MainActor (JSONValue) -> Void) -> () -> Void { {} }
        func setPreference(key _: String, value _: JSONValue, by _: SettingWriter) async throws {}
        func opened(_: URL) {}
        func openExternal(_: URL) {}
        func openFile(_: URL) {}
        func openAppLink(_: URL) -> Bool { false }
        func isRecent(_: String) -> Bool { false }
        func confirmOpen(_: URL, userGesture _: Bool) async -> Bool { false }
        func edited(_: URL, text _: String, baseHash _: String?, writable _: Bool) -> RecoveryDraftAcceptance { .kept }
        func saved(_: URL, hash _: String) {}
    }

    private final class Images: RemoteImageFetching {
        private(set) var requested: [URL] = []
        func fetch(_ url: URL) async -> PageResource? {
            requested.append(url)
            return PageResource(data: Data([0x89]), mimeType: "image/png")
        }
    }

    @Test func automaticRemoteImagesDefaultOff() {
        let look = FilePageLook(kind: .markdown, settings: { nil })
        #expect(!look.remoteImages)
    }

    @Test func aClickGrantsOnlyTheCurrentDocumentsResourcePrefix() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "md-images-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "privacy.md")
        try Data("![pixel](https://tracker.example/open.png)\n".utf8).write(to: file)
        let images = Images()
        let provider = FilePageProvider(kind: .markdown, file: file, host: Host(), libraries: nil, images: images)
        defer { provider.close() }
        let page = PageCallContext(page: FilePageKind.markdown.namespace)
        let clicked = PageCallContext(page: FilePageKind.markdown.namespace, userGesture: true)

        let initial = try await provider.call(FilePageKind.markdown.op("config"), params: [:], context: page)
        #expect(initial["remoteImageBase"] == nil)
        do {
            _ = try await provider.call(FilePageKind.markdown.op("loadRemoteImages"),
                                        params: ["path": .string(file.path)], context: page)
            Issue.record("a script granted remote images without a click")
        } catch let error as PageError {
            #expect(error.code == "cmux.page.gesture")
        }
        do {
            _ = try await provider.call(FilePageKind.markdown.op("loadRemoteImages"),
                                        params: ["path": .string(folder.appending(path: "other.md").path)], context: clicked)
            Issue.record("a click for another document granted this document's images")
        } catch let error as PageError {
            #expect(error.code == "cmux.protocol.invalid_params")
        }

        let approval = try await provider.call(FilePageKind.markdown.op("loadRemoteImages"),
                                               params: ["path": .string(file.path)], context: clicked)
        let base = try #require(approval["remoteImageBase"]?.stringValue)
        let baseURL = try #require(URL(string: base))
        let token = try #require(baseURL.pathComponents.last(where: { $0 != "/" && $0 != MarkdownPageResource.remoteImage }))
        let remote = try #require(URL(string: "https://tracker.example/open.png"))
        let encoded = RemoteImagePolicy.encode(remote)
        let resourceURL = try #require(URL(string: base + encoded))

        let refused = await provider.resource(for: PageResourceRequest(
            prefix: MarkdownPageResource.remoteImage,
            path: ["another-document", encoded],
            url: resourceURL
        ))
        #expect(refused == nil)
        #expect(images.requested.isEmpty)

        let loaded = await provider.resource(for: PageResourceRequest(
            prefix: MarkdownPageResource.remoteImage,
            path: [token, encoded],
            url: resourceURL
        ))
        #expect(loaded?.mimeType == "image/png")
        #expect(images.requested == [remote])
    }
}
