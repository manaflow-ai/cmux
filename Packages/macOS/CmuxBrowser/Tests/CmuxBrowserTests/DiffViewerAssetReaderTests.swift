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

    @Test(.timeLimit(.minutes(1)))
    func cancelledWaiterDoesNotBlockSubsequentAdmission() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data("asset".utf8).write(to: fixtureURL)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let reader = DiffViewerAssetReader(maximumWaitingStreams: 1)
        let activeID = UUID()
        let waitingID = UUID()
        _ = try await reader.read(streamID: activeID, fileURL: fixtureURL, upToCount: 1)

        let waiter = Task {
            try await reader.read(streamID: waitingID, fileURL: fixtureURL, upToCount: 1)
        }
        await Task.yield()
        waiter.cancel()
        await reader.close(streamID: activeID)

        do {
            _ = try await waiter.value
            Issue.record("Expected the queued stream to observe cancellation")
        } catch is CancellationError {
            // Expected whether cancellation wins before or after FIFO admission.
        }
        await reader.close(streamID: waitingID)

        let subsequentID = UUID()
        #expect(try await reader.read(
            streamID: subsequentID,
            fileURL: fixtureURL,
            upToCount: 5
        ) == Data("asset".utf8))
        await reader.close(streamID: subsequentID)
    }
}
