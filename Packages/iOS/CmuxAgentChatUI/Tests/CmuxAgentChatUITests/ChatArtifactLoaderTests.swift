import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxAgentChatUI

struct ChatArtifactLoaderTests {
    @Test func directoryRoutingRequiresTheNewFolderCapability() {
        let directory = ChatArtifactStat(
            exists: true,
            isDirectory: true,
            size: 0,
            modifiedAt: Date(timeIntervalSince1970: 0),
            kind: .directory,
            mimeType: nil
        )

        #expect(directory.showsFolder(supportsDirectoryBrowsing: true))
        #expect(!directory.showsFolder(supportsDirectoryBrowsing: false))
    }

    @Test func thumbnailCacheReusesSamePathAndDimension() async throws {
        let source = CountingArtifactSource()
        let loader = ChatArtifactLoader(
            source: source,
            sessionID: "session-1",
            cache: ChatArtifactThumbnailCache()
        )

        let first = try await loader.thumbnail(path: "/tmp/image.png", maxDimension: 256)
        let second = try await loader.thumbnail(path: "/tmp/image.png", maxDimension: 256)
        let third = try await loader.thumbnail(path: "/tmp/image.png", maxDimension: 512)

        #expect(first.data == Data([1, 2, 3]))
        #expect(second.data == Data([1, 2, 3]))
        #expect(third.data == Data([1, 2, 3]))
        #expect(first.pixelWidth == 256)
        #expect(second.pixelWidth == 256)
        #expect(third.pixelWidth == 512)
        #expect(await source.thumbnailRequestCount() == 2)
    }

    @Test func terminalScopeUsesDistinctCacheAndRoutesToTerminalClosures() async throws {
        let cache = ChatArtifactThumbnailCache()
        let chatSource = CountingArtifactSource()
        let chatLoader = ChatArtifactLoader(source: chatSource, sessionID: "session-1", cache: cache)
        let terminalSource = CountingTerminalArtifactSource()
        let terminalLoader = ChatArtifactLoader(
            terminalWorkspaceID: "workspace-1",
            terminalSurfaceID: "surface-1",
            supportsArtifacts: true,
            cache: cache,
            stat: { path in
                try await terminalSource.stat(path: path)
            },
            fetch: { path, progress in
                try await terminalSource.fetch(path: path, progress: progress)
            },
            thumbnail: { path, maxDimension in
                try await terminalSource.thumbnail(path: path, maxDimension: maxDimension)
            },
            list: { path in
                try await terminalSource.list(path: path)
            }
        )

        _ = try await chatLoader.thumbnail(path: "/tmp/image.png", maxDimension: 256)
        _ = try await terminalLoader.thumbnail(path: "/tmp/image.png", maxDimension: 256)
        _ = try await terminalLoader.thumbnail(path: "/tmp/image.png", maxDimension: 256)

        #expect(await chatSource.thumbnailRequestCount() == 1)
        #expect(await terminalSource.thumbnailRequestCount() == 1)
        #expect(try await terminalLoader.stat(path: "/tmp/image.png").kind == .image)
    }

    @Test func terminalListCapabilityRoutesAndFailsClosedWithoutCallingHandler() async throws {
        let source = CountingTerminalArtifactSource()
        let supported = ChatArtifactLoader(
            terminalWorkspaceID: "workspace-1",
            terminalSurfaceID: "surface-1",
            supportsArtifacts: true,
            supportsDirectoryBrowsing: true,
            stat: { path in try await source.stat(path: path) },
            fetch: { path, progress in try await source.fetch(path: path, progress: progress) },
            thumbnail: { path, dimension in
                try await source.thumbnail(path: path, maxDimension: dimension)
            },
            list: { path in try await source.list(path: path) }
        )
        let unsupported = ChatArtifactLoader(
            terminalWorkspaceID: "workspace-1",
            terminalSurfaceID: "surface-1",
            supportsArtifacts: true,
            stat: { path in try await source.stat(path: path) },
            fetch: { path, progress in try await source.fetch(path: path, progress: progress) },
            thumbnail: { path, dimension in
                try await source.thumbnail(path: path, maxDimension: dimension)
            },
            list: { path in try await source.list(path: path) }
        )

        #expect(try await supported.list(path: "/tmp/folder").entries.first?.name == "child.txt")
        #expect(await source.listRequestCount() == 1)
        do {
            _ = try await unsupported.list(path: "/tmp/folder")
            Issue.record("unsupported loader should not issue a list request")
        } catch let error as ChatArtifactError {
            #expect(error == .unsupported)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await source.listRequestCount() == 1)
    }
}

private actor CountingArtifactSource: ChatEventSource {
    nonisolated let supportsArtifacts = true
    private var requests = 0

    func thumbnailRequestCount() -> Int {
        requests
    }

    func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage {
        throw ChatArtifactError.unsupported
    }

    func events(sessionID: String) async -> AsyncStream<ChatSessionEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func send(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws {
        throw ChatArtifactError.unsupported
    }

    func interrupt(sessionID: String, hard: Bool) async throws {
        throw ChatArtifactError.unsupported
    }

    func answer(optionIndex: Int, sessionID: String) async throws {
        throw ChatArtifactError.unsupported
    }

    func artifactStat(sessionID: String, path: String) async throws -> ChatArtifactStat {
        throw ChatArtifactError.unsupported
    }

    func artifactFetch(
        sessionID: String,
        path: String,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?
    ) async throws -> Data {
        throw ChatArtifactError.unsupported
    }

    func artifactThumbnail(
        sessionID: String,
        path: String,
        maxDimension: Int
    ) async throws -> ChatArtifactThumbnail {
        requests += 1
        return ChatArtifactThumbnail(data: Data([1, 2, 3]), pixelWidth: maxDimension, pixelHeight: maxDimension)
    }

    func artifactList(sessionID: String, path: String) async throws -> ChatArtifactDirectoryListing {
        throw ChatArtifactError.unsupported
    }
}

private actor CountingTerminalArtifactSource {
    private var thumbnails = 0
    private var lists = 0

    func thumbnailRequestCount() -> Int {
        thumbnails
    }

    func listRequestCount() -> Int {
        lists
    }

    func stat(path: String) async throws -> ChatArtifactStat {
        ChatArtifactStat(
            exists: true,
            isDirectory: false,
            size: 3,
            modifiedAt: Date(timeIntervalSince1970: 0),
            kind: .image,
            mimeType: "image/png"
        )
    }

    func fetch(
        path: String,
        progress: (@Sendable (_ fetchedBytes: Int64, _ totalBytes: Int64) -> Void)?
    ) async throws -> Data {
        Data([4, 5, 6])
    }

    func thumbnail(path: String, maxDimension: Int) async throws -> ChatArtifactThumbnail {
        thumbnails += 1
        return ChatArtifactThumbnail(data: Data([7, 8, 9]), pixelWidth: maxDimension, pixelHeight: maxDimension)
    }

    func list(path: String) async throws -> ChatArtifactDirectoryListing {
        lists += 1
        return ChatArtifactDirectoryListing(entries: [
            ChatArtifactDirectoryEntry(name: "child.txt", isDirectory: false, size: 1, kind: .text),
        ])
    }
}
