import CmuxAgentChat
import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShell

@Suite
struct MobileArtifactLaneFetchLoopTests {
    @Test
    func convertsRawBytesIntoExactBackpressuredChunks() async throws {
        let connection = ArtifactLaneConnectionScript(steps: [
            .bytes(Data("abc".utf8)),
            .bytes(Data("de".utf8)),
        ])
        let recorder = ArtifactLaneChunkRecorder()
        let descriptor = ChatArtifactLaneDescriptor(
            resourceID: "opaque-resource",
            totalSize: 5,
            expiresAt: Date().addingTimeInterval(30)
        )

        let data = try await MobileArtifactLaneFetchLoop().run(
            descriptor: descriptor,
            connection: connection,
            collectsData: true,
            progress: nil
        ) { chunk in
            await recorder.record(chunk)
        }

        #expect(data == Data("abcde".utf8))
        #expect(await recorder.chunks() == [
            ChatArtifactChunk(data: Data("abc".utf8), offset: 0, totalSize: 5, eof: false),
            ChatArtifactChunk(data: Data("de".utf8), offset: 3, totalSize: 5, eof: true),
        ])
        let snapshot = await connection.snapshot()
        #expect(snapshot.maximumByteCounts == [64 * 1_024, 64 * 1_024, 64 * 1_024])
        #expect(snapshot.closeCount == 1)
    }

    @Test
    func emitsOneEmptyEOFChunkForZeroByteArtifact() async throws {
        let connection = ArtifactLaneConnectionScript(steps: [.eof])
        let recorder = ArtifactLaneChunkRecorder()
        let descriptor = ChatArtifactLaneDescriptor(
            resourceID: "empty-resource",
            totalSize: 0,
            expiresAt: Date().addingTimeInterval(30)
        )

        let data = try await MobileArtifactLaneFetchLoop().run(
            descriptor: descriptor,
            connection: connection,
            collectsData: true,
            progress: nil
        ) { chunk in
            await recorder.record(chunk)
        }

        #expect(data.isEmpty)
        #expect(await recorder.chunks() == [
            ChatArtifactChunk(data: Data(), offset: 0, totalSize: 0, eof: true),
        ])
        #expect(await connection.snapshot().closeCount == 1)
    }

    @Test
    func classifiesFailureBeforeFirstByteForSafeRPCFallback() async {
        let connection = ArtifactLaneConnectionScript(steps: [.failure])
        let descriptor = ChatArtifactLaneDescriptor(
            resourceID: "unstarted-resource",
            totalSize: 8,
            expiresAt: Date().addingTimeInterval(30)
        )

        await #expect(throws: MobileArtifactLaneFetchError.failedBeforeFirstByte) {
            _ = try await MobileArtifactLaneFetchLoop().run(
                descriptor: descriptor,
                connection: connection,
                collectsData: false,
                progress: nil
            ) { _ in }
        }
        #expect(await connection.snapshot().closeCount == 1)
    }

    @Test
    func classifiesFailureAfterBytesToPreventMixedTransportData() async {
        let connection = ArtifactLaneConnectionScript(steps: [
            .bytes(Data("abc".utf8)),
            .failure,
        ])
        let descriptor = ChatArtifactLaneDescriptor(
            resourceID: "partial-resource",
            totalSize: 8,
            expiresAt: Date().addingTimeInterval(30)
        )

        await #expect(throws: MobileArtifactLaneFetchError.failedAfterFirstByte) {
            _ = try await MobileArtifactLaneFetchLoop().run(
                descriptor: descriptor,
                connection: connection,
                collectsData: false,
                progress: nil
            ) { _ in }
        }
        #expect(await connection.snapshot().closeCount == 1)
    }

    @Test
    func rejectsAnOverrunAfterDeliveredBytesAsNonFallbackFailure() async {
        let connection = ArtifactLaneConnectionScript(steps: [
            .bytes(Data("abc".utf8)),
            .bytes(Data("def".utf8)),
        ])
        let descriptor = ChatArtifactLaneDescriptor(
            resourceID: "overrun-resource",
            totalSize: 5,
            expiresAt: Date().addingTimeInterval(30)
        )

        await #expect(throws: MobileArtifactLaneFetchError.failedAfterFirstByte) {
            _ = try await MobileArtifactLaneFetchLoop().run(
                descriptor: descriptor,
                connection: connection,
                collectsData: false,
                progress: nil
            ) { _ in }
        }
        #expect(await connection.snapshot().closeCount == 1)
    }

    @Test
    func rejectsBytesAfterTheDeclaredSizeBeforeReportingFinalEOF() async {
        let connection = ArtifactLaneConnectionScript(steps: [
            .bytes(Data("abcde".utf8)),
            .bytes(Data("x".utf8)),
        ])
        let recorder = ArtifactLaneChunkRecorder()
        let descriptor = ChatArtifactLaneDescriptor(
            resourceID: "trailing-byte-resource",
            totalSize: 5,
            expiresAt: Date().addingTimeInterval(30)
        )

        await #expect(throws: MobileArtifactLaneFetchError.failedAfterFirstByte) {
            _ = try await MobileArtifactLaneFetchLoop().run(
                descriptor: descriptor,
                connection: connection,
                collectsData: false,
                progress: nil
            ) { chunk in
                await recorder.record(chunk)
            }
        }
        #expect(await recorder.chunks().isEmpty)
        #expect(await connection.snapshot().closeCount == 1)
    }

    @Test
    func propagatesCancellationAndClosesTheLane() async {
        let connection = ArtifactLaneConnectionScript(steps: [.cancelled])
        let descriptor = ChatArtifactLaneDescriptor(
            resourceID: "cancelled-resource",
            totalSize: 5,
            expiresAt: Date().addingTimeInterval(30)
        )

        await #expect(throws: CancellationError.self) {
            _ = try await MobileArtifactLaneFetchLoop().run(
                descriptor: descriptor,
                connection: connection,
                collectsData: false,
                progress: nil
            ) { _ in }
        }
        #expect(await connection.snapshot().closeCount == 1)
    }
}

private actor ArtifactLaneConnectionScript: MobileArtifactLaneConnection {
    enum Step: Sendable {
        case bytes(Data)
        case eof
        case failure
        case cancelled
    }

    struct Snapshot: Sendable {
        let maximumByteCounts: [Int]
        let closeCount: Int
    }

    private var steps: [Step]
    private var maximumByteCounts: [Int] = []
    private var closeCount = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func receive(maximumByteCount: Int) async throws -> Data? {
        maximumByteCounts.append(maximumByteCount)
        guard !steps.isEmpty else { return nil }
        switch steps.removeFirst() {
        case let .bytes(data):
            return data
        case .eof:
            return nil
        case .failure:
            throw ArtifactLaneScriptError.failed
        case .cancelled:
            throw CancellationError()
        }
    }

    func close() async {
        closeCount += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(maximumByteCounts: maximumByteCounts, closeCount: closeCount)
    }
}

private actor ArtifactLaneChunkRecorder {
    private var values: [ChatArtifactChunk] = []

    func record(_ chunk: ChatArtifactChunk) {
        values.append(chunk)
    }

    func chunks() -> [ChatArtifactChunk] {
        values
    }
}

private enum ArtifactLaneScriptError: Error {
    case failed
}
