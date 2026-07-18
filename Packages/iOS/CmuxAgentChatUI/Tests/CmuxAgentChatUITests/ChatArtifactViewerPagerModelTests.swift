import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxAgentChatUI

@Suite("Artifact viewer pager ownership")
struct ChatArtifactViewerPagerModelTests {
    @Test("keeps page identity stable across gallery snapshot updates")
    @MainActor
    func keepsStablePageIdentity() throws {
        let suiteName = "cmux.viewer-pager.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initialOrder = swipeOrder([
            item(path: "/logs/build.log", size: 11_000_000),
            item(path: "/logs/test.log", size: 2_000),
        ])
        let model = ChatArtifactViewerPagerModel(
            initialPath: "/logs/build.log",
            swipeOrder: initialOrder,
            textPreferences: ChatArtifactTextPreferences(defaults: defaults)
        )
        let initialIdentity = try #require(model.pageIdentity(for: "/logs/build.log"))

        model.update(swipeOrder: swipeOrder([
            item(path: "/logs/new.log", size: 40),
            item(path: "/logs/build.log", size: 11_500_000),
            item(path: "/logs/test.log", size: 2_000),
        ]))

        #expect(model.pageIdentity(for: "/logs/build.log") == initialIdentity)
        #expect(model.pageSnapshots.map(\.path) == [
            "/logs/new.log",
            "/logs/build.log",
            "/logs/test.log",
        ])
    }

    @Test("projects toolbar state from exactly the selected page")
    @MainActor
    func projectsOneToolbarState() throws {
        let suiteName = "cmux.viewer-toolbar.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = ChatArtifactViewerPagerModel(
            initialPath: "/first.txt",
            swipeOrder: swipeOrder([
                item(path: "/first.txt", size: 10),
                item(path: "/second.txt", size: 20),
                item(path: "/third.txt", size: 30),
            ]),
            textPreferences: ChatArtifactTextPreferences(defaults: defaults)
        )

        #expect(model.toolbarSnapshot.path == "/first.txt")
        model.select(path: "/second.txt")
        #expect(model.toolbarSnapshot.path == "/second.txt")
        #expect(model.pageSnapshots.count == 3)
    }

    @Test("projects the highlighting pill only from the selected page")
    @MainActor
    func projectsSelectedPagePill() async throws {
        let suiteName = "cmux.viewer-pill.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let logPath = "/logs/build.log"
        let csvPath = "/data.csv"
        let logSize = ChatArtifactSyntaxHighlightPolicy.maxHighlightBytes + 1
        let loader = ChatArtifactLoader(
            supportsArtifacts: true,
            stat: { path in
                ChatArtifactStat(
                    exists: true,
                    isDirectory: false,
                    size: path == logPath ? logSize : 1,
                    modifiedAt: Date(timeIntervalSince1970: 1),
                    kind: .text,
                    mimeType: "text/plain"
                )
            },
            stream: { path, onChunk in
                let totalSize = path == logPath ? logSize : 1
                try await onChunk(ChatArtifactChunk(
                    data: Data("x".utf8),
                    offset: 0,
                    totalSize: totalSize,
                    eof: true
                ))
            }
        )
        let model = ChatArtifactViewerPagerModel(
            initialPath: logPath,
            swipeOrder: swipeOrder([
                item(path: logPath, size: logSize),
                item(path: csvPath, size: 1),
            ]),
            textPreferences: ChatArtifactTextPreferences(defaults: defaults)
        )

        await model.actions(
            for: logPath,
            loader: loader,
            quickLookCanPreview: { _ in false }
        ).load()
        await model.actions(
            for: csvPath,
            loader: loader,
            quickLookCanPreview: { _ in false }
        ).load()

        #expect(model.toolbarSnapshot.path == logPath)
        #expect(model.toolbarSnapshot.showsHighlightingStatusPill)
        model.select(path: csvPath)
        #expect(model.toolbarSnapshot.path == csvPath)
        #expect(!model.toolbarSnapshot.showsHighlightingStatusPill)
    }

    @Test("streamed snapshots and gallery refreshes do not replay jump requests")
    @MainActor
    func keepsJumpRequestIdentity() async throws {
        let suiteName = "cmux.viewer-jumps.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let path = "/build-\(UUID().uuidString).log"
        let firstData = Data("first\n".utf8)
        let secondData = Data("second\n".utf8)
        let totalSize = Int64(firstData.count + secondData.count)
        let stream = ControlledArtifactStream(chunks: [
            ChatArtifactChunk(data: firstData, offset: 0, totalSize: totalSize, eof: false),
            ChatArtifactChunk(
                data: secondData,
                offset: Int64(firstData.count),
                totalSize: totalSize,
                eof: true
            ),
        ])
        let loader = ChatArtifactLoader(
            supportsArtifacts: true,
            stat: { _ in
                ChatArtifactStat(
                    exists: true,
                    isDirectory: false,
                    size: totalSize,
                    modifiedAt: Date(timeIntervalSince1970: 1),
                    kind: .text,
                    mimeType: "text/plain"
                )
            },
            stream: { _, onChunk in
                try await stream.fetch(onChunk: onChunk)
            }
        )
        let model = ChatArtifactViewerPagerModel(
            initialPath: path,
            swipeOrder: swipeOrder([item(path: path, size: totalSize)]),
            textPreferences: ChatArtifactTextPreferences(defaults: defaults)
        )
        let identity = try #require(model.pageIdentity(for: path))

        model.requestTop()
        let requestID = model.toolbarSnapshot.topRequestID
        let actions = model.actions(
            for: path,
            loader: loader,
            quickLookCanPreview: { _ in false }
        )
        let loadTask = Task { await actions.load() }
        await stream.waitUntilFirstChunkDelivered()

        #expect(model.pageIdentity(for: path) == identity)
        #expect(model.toolbarSnapshot.textChunks == ["first\n"])
        #expect(model.toolbarSnapshot.topRequestID == requestID)
        model.update(swipeOrder: swipeOrder([
            item(path: path, size: totalSize),
            item(path: "/new.log", size: 100),
        ]))

        #expect(requestID == 1)
        #expect(model.pageIdentity(for: path) == identity)
        #expect(model.toolbarSnapshot.topRequestID == requestID)

        await stream.resume()
        await loadTask.value
        #expect(model.toolbarSnapshot.textChunks == ["first\n", "second\n"])
        #expect(model.toolbarSnapshot.topRequestID == requestID)
    }

    private func swipeOrder(_ items: [ChatArtifactGalleryItem]) -> ChatArtifactGallerySwipeOrder {
        ChatArtifactGallerySwipeOrder(items: items)
    }

    private func item(path: String, size: Int64) -> ChatArtifactGalleryItem {
        ChatArtifactGalleryItem(
            path: path,
            kind: .text,
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            size: size,
            modifiedAt: Date(timeIntervalSince1970: Double(size))
        )
    }
}
