#if DEBUG
import Foundation
import Testing
import CmuxMobileShellModel
@testable import CmuxMobileShellReleaseGateSupport

@MainActor
struct MobileIrohReleaseGateTerminalSessionTests {
    @Test func repeatedInputKeepsOneConsumerAndProcessesIdleOutput() async throws {
        let client = ProbeTerminalClient(replies: ["first", "second", "third"])
        let session = MobileIrohReleaseGateTerminalSession(client: client)
        defer { session.reset() }
        try await session.verify(surfaceID: "a", marker: "first")
        client.emit("background output", surfaceID: "a")
        try await session.verify(surfaceID: "a", marker: "second")
        try await session.verify(surfaceID: "a", marker: "third")
        #expect(client.mounts == ["a"])
        #expect(client.acknowledged == 4)
    }

    @Test func switchesAndExplicitReconnectReleaseTheirPriorConsumer() async throws {
        let client = ProbeTerminalClient(replies: ["one", "two", "three", "four"])
        let session = MobileIrohReleaseGateTerminalSession(client: client)
        defer { session.reset() }
        try await session.verify(surfaceID: "a", marker: "one")
        try await session.verify(surfaceID: "b", marker: "two")
        try await session.verify(surfaceID: "a", marker: "three")
        session.reset()
        try await session.verify(surfaceID: "a", marker: "four")
        #expect(client.mounts == ["a", "b", "a", "a"])
        #expect(client.releases == 3)
    }

    @Test func aReplacedConsumerFailsInsteadOfStealingOwnership() async throws {
        let client = ProbeTerminalClient(replies: ["one", "two"])
        let session = MobileIrohReleaseGateTerminalSession(client: client)
        defer { session.reset() }
        try await session.verify(surfaceID: "a", marker: "one")
        client.owners["a"] = UUID()
        await #expect(throws: MobileIrohReleaseGateProbeFailure.terminalRoundTripFailed) {
            try await session.verify(surfaceID: "a", marker: "two")
        }
        #expect(client.mounts == ["a"])
    }

    @Test func cancellationReleasesTheReader() async throws {
        let client = ProbeTerminalClient(replies: [])
        let session = MobileIrohReleaseGateTerminalSession(client: client)
        let pending = Task { try await session.verify(surfaceID: "a", marker: "never") }
        for await _ in client.inputStarted.stream.prefix(1) {}
        pending.cancel()
        do { try await pending.value; Issue.record("cancelled probe passed") }
        catch is CancellationError {}
        session.reset()
        for await _ in client.terminated.stream.prefix(1) {}
        #expect(client.owners.isEmpty)
    }
}

@MainActor
private final class ProbeTerminalClient: MobileIrohReleaseGateTerminalClient {
    var replies: [String]
    var owners: [String: UUID] = [:]
    var outputs: [String: AsyncStream<MobileTerminalOutputChunk>.Continuation] = [:]
    var mounts: [String] = []
    var releases = 0
    var acknowledged = 0
    let inputStarted = AsyncStream<Void>.makeStream()
    let terminated = AsyncStream<Void>.makeStream()
    init(replies: [String]) { self.replies = replies }
    func terminalOutputStream(surfaceID: String, ownerID: UUID?) -> AsyncStream<MobileTerminalOutputChunk> {
        let (stream, continuation) = AsyncStream<MobileTerminalOutputChunk>.makeStream()
        owners[surfaceID] = ownerID
        outputs[surfaceID] = continuation
        mounts.append(surfaceID)
        let signal = terminated.continuation
        continuation.onTermination = { _ in signal.yield(()) }
        return stream
    }
    func isTerminalOutputConsumerOwner(surfaceID: String, ownerID: UUID) -> Bool { owners[surfaceID] == ownerID }
    func clearTerminalOutputConsumerOwner(surfaceID: String, ownerID: UUID) {
        guard owners[surfaceID] == ownerID else { return }
        owners[surfaceID] = nil
        releases += 1
    }
    func terminalOutputDidProcess(surfaceID: String, streamToken: UUID) { acknowledged += 1 }
    func submitTerminalRawInput(_ data: Data, surfaceID: String) async {
        inputStarted.continuation.yield(())
        if !replies.isEmpty { emit(replies.removeFirst(), surfaceID: surfaceID) }
    }
    func emit(_ text: String, surfaceID: String) {
        outputs[surfaceID]?.yield(MobileTerminalOutputChunk(data: Data(text.utf8), streamToken: UUID()))
    }
}
#endif
