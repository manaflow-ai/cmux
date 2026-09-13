import Darwin
import Dispatch
import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("WorkstreamStore persistence scheduling")
struct WorkstreamStorePersistenceSchedulingTests {
    @Test("ingest submits persistence appends without waiting for MainActor")
    func ingestSubmitsPersistenceAppendOffMainActor() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-ingest-scheduling-\(UUID().uuidString).jsonl")
        #expect(FileManager.default.createFile(atPath: fileURL.path, contents: nil))

        let fileDescriptor = open(fileURL.path, O_EVTONLY)
        try #require(fileDescriptor >= 0, "failed to observe the persistence file")

        let appendObserved = DispatchSemaphore(value: 0)
        let observerCancelled = DispatchSemaphore(value: 0)
        let observer = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .extend,
            queue: .global(qos: .userInitiated)
        )
        observer.setEventHandler {
            appendObserved.signal()
        }
        observer.setCancelHandler {
            close(fileDescriptor)
            observerCancelled.signal()
        }
        observer.resume()
        defer {
            observer.cancel()
            _ = Self.wait(for: observerCancelled, timeout: .now() + .seconds(1))
            try? FileManager.default.removeItem(at: fileURL)
        }

        let persistence = WorkstreamPersistence(fileURL: fileURL)
        let appendedWhileMainActorWasOccupied = await MainActor.run {
            let store = WorkstreamStore(persistence: persistence, ringCapacity: 10)
            store.ingest(WorkstreamEvent(
                sessionId: "persistence-scheduling",
                hookEventName: .sessionStart,
                source: "codex"
            ))
            return appendObserved.wait(timeout: .now() + .seconds(1)) == .success
        }

        #expect(
            appendedWhileMainActorWasOccupied,
            "the persistence append must make progress while MainActor is occupied"
        )

        if !appendedWhileMainActorWasOccupied {
            #expect(
                Self.wait(for: appendObserved, timeout: .now() + .seconds(2)) == .success,
                "the queued append did not complete after MainActor was released"
            )
        }
    }

    private static func wait(
        for semaphore: DispatchSemaphore,
        timeout: DispatchTime
    ) -> DispatchTimeoutResult {
        semaphore.wait(timeout: timeout)
    }
}
