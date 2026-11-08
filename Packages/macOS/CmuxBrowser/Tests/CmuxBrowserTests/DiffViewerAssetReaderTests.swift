import Darwin
import Foundation
import Testing
@testable import CmuxBrowser

@Suite("DiffViewerAssetReader")
struct DiffViewerAssetReaderTests {
    @Test
    func rejectsAConcurrentStreamWhenWaitingCapacityIsZero() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data("asset".utf8).write(to: fixtureURL)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let reader = DiffViewerAssetReader(maximumWaitingStreams: 0)
        let activeID = UUID()
        _ = try await reader.read(streamID: activeID, fileURL: fixtureURL, upToCount: 1)

        do {
            _ = try await reader.read(
                streamID: UUID(),
                fileURL: fixtureURL,
                upToCount: 1
            )
            Issue.record("Expected bounded admission to reject the concurrent stream")
        } catch let error as DiffViewerAssetReaderError {
            #expect(error == .capacityExceeded)
        }

        await reader.close(streamID: activeID)
        let subsequentID = UUID()
        #expect(try await reader.read(
            streamID: subsequentID,
            fileURL: fixtureURL,
            upToCount: 5
        ) == Data("asset".utf8))
        await reader.close(streamID: subsequentID)
    }

    @Test
    func rejectsFIFOAssetsWithoutBlocking() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try #require(mkfifo(fixtureURL.path, mode_t(0o600)) == 0)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let keeperDescriptor = Darwin.open(
            fixtureURL.path,
            O_RDWR | O_NONBLOCK | O_CLOEXEC
        )
        try #require(keeperDescriptor >= 0)
        defer { Darwin.close(keeperDescriptor) }

        var marker: UInt8 = 0x41
        let written = withUnsafeBytes(of: &marker) { buffer in
            Darwin.write(keeperDescriptor, buffer.baseAddress, buffer.count)
        }
        try #require(written == 1)

        let reader = DiffViewerAssetReader()
        await #expect(throws: CocoaError.self) {
            _ = try await reader.read(
                streamID: UUID(),
                fileURL: fixtureURL,
                upToCount: 1
            )
        }
    }

    @Test
    func cancelledWaiterDoesNotBlockSubsequentAdmission() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data("asset".utf8).write(to: fixtureURL)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let (queuedStreams, queuedStreamContinuation) = AsyncStream<UUID>.makeStream()
        var queuedStreamIterator = queuedStreams.makeAsyncIterator()
        let reader = DiffViewerAssetReader(
            maximumWaitingStreams: 1,
            waitingStreamDidEnqueue: { queuedStreamContinuation.yield($0) }
        )
        defer { queuedStreamContinuation.finish() }
        let activeID = UUID()
        let waitingID = UUID()
        _ = try await reader.read(streamID: activeID, fileURL: fixtureURL, upToCount: 1)

        let waiter = Task {
            try await reader.read(streamID: waitingID, fileURL: fixtureURL, upToCount: 1)
        }
        #expect(await queuedStreamIterator.next() == waitingID)
        waiter.cancel()

        do {
            _ = try await waiter.value
            Issue.record("Expected the queued stream to observe cancellation")
        } catch is CancellationError {
            // Expected after the actor removes the cancelled queued stream.
        }

        let subsequentID = UUID()
        let subsequent = Task {
            try await reader.read(
                streamID: subsequentID,
                fileURL: fixtureURL,
                upToCount: 5
            )
        }
        #expect(await queuedStreamIterator.next() == subsequentID)
        await reader.close(streamID: activeID)
        #expect(try await subsequent.value == Data("asset".utf8))
        await reader.close(streamID: subsequentID)
    }
}
