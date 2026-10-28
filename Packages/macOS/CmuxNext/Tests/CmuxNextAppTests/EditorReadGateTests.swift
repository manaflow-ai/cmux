@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// View Metrics' tab waits for its file (`FilePageProvider.ready`) only once: a failed write fails
/// the page's first read with the write's reason, and the page's Retry reads the file again (the
/// gate does not fail it for ever).
@MainActor @Suite struct EditorReadGateTests {
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

    @Test func aFailedWriteFailsTheFirstReadAndRetryReadsTheFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "editor-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "metrics.json")
        let provider = FilePageProvider(kind: .editor, file: url, host: Host(), libraries: nil, images: NoImages())
        defer { provider.close() }
        provider.ready = { "the write failed" }
        let context = PageCallContext(page: FilePageKind.editor.namespace)

        do {
            _ = try await provider.call(FilePageKind.editor.op("config"), params: .object([:]), context: context)
            Issue.record("the first read did not fail")
        } catch let error as PageError {
            #expect(error.message.contains("the write failed"), "the page's error is not the write's reason: \(error.message)")
        }

        try Data("{}\n".utf8).write(to: url)
        let retry = try await provider.call(FilePageKind.editor.op("config"), params: .object([:]), context: context)
        #expect(retry["text"]?.stringValue == "{}\n", "Retry did not read the file")
    }
}
