import CmuxTerminalRenderTransport
import Foundation
import Testing
@testable import CmuxGhosttyRenderClient

@Suite(.serialized) struct GhosttyRenderWorkerClientTests {
    @Test func sendsOrderedSurfaceOutputThroughRealProcess() async throws {
        let client = try GhosttyRenderWorkerClient(executableURL: fixtureURL())
        let collector = EventCollector(stream: await client.subscribeEvents())
        await client.updateConfiguration(configuration())

        let id = UUID()
        let descriptor = surfaceDescriptor(id: id, generation: 4)
        client.commandSink.enqueue(.createSurface(descriptor))
        client.commandSink.enqueue(.mutateSurface(
            id: id,
            generation: 4,
            mutation: .processOutput(sequence: 0, bytes: Data("hello".utf8))
        ))

        let events = await collector.waitUntil { events in
            events.contains(.outputApplied(
                surfaceID: id,
                surfaceGeneration: 4,
                nextSequence: 5
            ))
        }
        await client.shutdown()

        #expect(events.contains { event in
            if case .initialized = event { return true }
            return false
        })
        #expect(events.contains(.surfaceCreated(
            surfaceID: id,
            surfaceGeneration: 4
        )))
    }

    @Test func preservesChildStdoutEventOrder() async throws {
        let client = try GhosttyRenderWorkerClient(executableURL: fixtureURL())
        let collector = EventCollector(stream: await client.subscribeEvents())
        await client.updateConfiguration(configuration())

        let id = UUID()
        let descriptor = surfaceDescriptor(id: id, generation: 5)
        client.commandSink.enqueue(.createSurface(descriptor))
        for sequence in 0..<128 {
            client.commandSink.enqueue(.mutateSurface(
                id: id,
                generation: 5,
                mutation: .processOutput(
                    sequence: UInt64(sequence),
                    bytes: Data([UInt8(sequence)])
                )
            ))
        }

        let events = await collector.waitUntil { events in
            events.contains(.outputApplied(
                surfaceID: id,
                surfaceGeneration: 5,
                nextSequence: 128
            ))
        }
        await client.shutdown()

        let outputSequences = events.compactMap { event -> UInt64? in
            guard case let .outputApplied(surfaceID, generation, nextSequence) = event,
                  surfaceID == id,
                  generation == 5 else {
                return nil
            }
            return nextSequence
        }
        #expect(outputSequences == (1...128).map(UInt64.init))

        let initializedIndex = events.firstIndex { event in
            if case .initialized = event { return true }
            return false
        }
        let surfaceIndex = events.firstIndex(of: .surfaceCreated(
            surfaceID: id,
            surfaceGeneration: 5
        ))
        let firstOutputIndex = events.firstIndex(of: .outputApplied(
            surfaceID: id,
            surfaceGeneration: 5,
            nextSequence: 1
        ))
        #expect(initializedIndex != nil)
        #expect(surfaceIndex != nil)
        #expect(firstOutputIndex != nil)
        if let initializedIndex, let surfaceIndex, let firstOutputIndex {
            #expect(initializedIndex < surfaceIndex)
            #expect(surfaceIndex < firstOutputIndex)
        }
    }

    @Test func restartsHungWorkerOnceWithoutDuplicateExitEvents() async throws {
        let client = try GhosttyRenderWorkerClient(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            initializationTimeout: .milliseconds(100),
            automaticInitializationRetryLimit: 1
        )
        let collector = EventCollector(stream: await client.subscribeEvents())
        await client.updateConfiguration(configuration())

        _ = await collector.waitUntil(timeout: .seconds(3)) { events in
            events.filter { event in
                if case .workerExited = event { return true }
                return false
            }.count == 2
        }
        try? await Task.sleep(for: .milliseconds(200))
        let events = await collector.snapshot()
        await client.shutdown()

        let lifecycle = events.compactMap { event -> String? in
            switch event {
            case let .failure(message) where message == "worker initialization timed out":
                return "timeout"
            case let .workerExited(generation):
                return "exit-\(generation)"
            default:
                return nil
            }
        }
        #expect(lifecycle == ["timeout", "exit-1", "timeout", "exit-2"])
        #expect(!events.contains { event in
            if case .initialized = event { return true }
            return false
        })
    }

    @Test func crashRequestsSnapshotBeforeQueuedOutputResumes() async throws {
        let crashMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-render-crash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: crashMarker) }

        let client = try GhosttyRenderWorkerClient(
            executableURL: fixtureURL(),
            environment: [
                "CMUX_GHOSTTY_RENDER_FIXTURE_CRASH_ONCE_FILE": crashMarker.path,
            ]
        )
        let collector = EventCollector(stream: await client.subscribeEvents())
        await client.updateConfiguration(configuration())
        _ = await collector.waitUntil { events in
            events.contains { event in
                if case .workerExited = event { return true }
                return false
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        let initialCrashEvents = await collector.snapshot()
        let initialLifecycle = initialCrashEvents.compactMap { event -> String? in
            switch event {
            case .initialized:
                return "initialized"
            case let .workerExited(generation):
                return "exit-\(generation)"
            default:
                return nil
            }
        }
        #expect(initialLifecycle == ["initialized", "exit-1"])

        let id = UUID()
        let descriptor = surfaceDescriptor(id: id, generation: 8)
        client.commandSink.enqueue(.createSurface(descriptor))
        client.commandSink.enqueue(.mutateSurface(
            id: id,
            generation: 8,
            mutation: .processOutput(sequence: 11, bytes: Data("tail".utf8))
        ))

        let recoveryEvents = await collector.waitUntil { events in
            events.contains(.resynchronizationRequired(
                surfaceID: id,
                surfaceGeneration: 8
            ))
        }
        #expect(recoveryEvents.contains(.resynchronizationRequired(
            surfaceID: id,
            surfaceGeneration: 8
        )))

        client.commandSink.enqueue(.resynchronizeSurface(
            descriptor: descriptor,
            nextOutputSequence: 11,
            screenTailVT: Data("snapshot".utf8)
        ))
        let completed = await collector.waitUntil { events in
            events.contains(.outputApplied(
                surfaceID: id,
                surfaceGeneration: 8,
                nextSequence: 15
            ))
        }
        await client.shutdown()

        #expect(completed.contains(.surfaceCreated(
            surfaceID: id,
            surfaceGeneration: 8
        )))
    }

    private func configuration() -> TerminalRenderConfigurationSnapshot {
        TerminalRenderConfigurationSnapshot(
            revision: 1,
            contents: "font-size = 14\n"
        )
    }

    private func surfaceDescriptor(
        id: UUID,
        generation: UInt64
    ) -> TerminalRenderSurfaceDescriptor {
        TerminalRenderSurfaceDescriptor(
            id: id,
            generation: generation,
            width: 800,
            height: 600,
            scaleX: 2,
            scaleY: 2,
            fontSize: 14,
            context: 1
        )
    }
}

private actor EventCollector {
    private var events: [GhosttyRenderWorkerClientEvent] = []
    private var pump: Task<Void, Never>?

    init(stream: AsyncStream<GhosttyRenderWorkerClientEvent>) {
        Task { await start(stream) }
    }

    private func start(_ stream: AsyncStream<GhosttyRenderWorkerClientEvent>) {
        pump = Task {
            for await event in stream {
                events.append(event)
            }
        }
    }

    func waitUntil(
        timeout: Duration = .seconds(10),
        _ predicate: @escaping @Sendable ([GhosttyRenderWorkerClientEvent]) -> Bool
    ) async -> [GhosttyRenderWorkerClientEvent] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate(events) { return events }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return events
    }

    func snapshot() -> [GhosttyRenderWorkerClientEvent] {
        events
    }
}

private func fixtureURL() -> URL {
    builtExecutableURL(named: "cmux-ghostty-render-fixture")
}

private func builtExecutableURL(named name: String) -> URL {
    let fileManager = FileManager.default
    var candidates: [URL] = []
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(name))
    }
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let buildDirectory = packageRoot.appendingPathComponent(".build")
    candidates.append(buildDirectory.appendingPathComponent("debug").appendingPathComponent(name))
    if let triples = try? fileManager.contentsOfDirectory(
        at: buildDirectory,
        includingPropertiesForKeys: nil
    ) {
        for triple in triples {
            candidates.append(triple.appendingPathComponent("debug").appendingPathComponent(name))
        }
    }
    return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
        ?? candidates[0]
}
