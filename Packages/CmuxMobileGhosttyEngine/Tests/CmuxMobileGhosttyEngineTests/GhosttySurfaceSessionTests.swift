import Foundation
import Testing
@testable import CmuxMobileGhosttyEngine

@Suite struct GhosttySurfaceSessionTests {
    private func makeSession(
        backend: ScriptedSurfaceBackend
    ) -> (GhosttySurfaceSession, AsyncStream<GhosttySurfaceHostEvent>) {
        let (stream, continuation) = AsyncStream.makeStream(of: GhosttySurfaceHostEvent.self)
        let session = GhosttySurfaceSession(backend: backend, events: continuation)
        return (session, stream)
    }

    /// Collects every event until the stream finishes (i.e. after shutdown
    /// drains and the backend is freed).
    private func drain(_ stream: AsyncStream<GhosttySurfaceHostEvent>) async -> [GhosttySurfaceHostEvent] {
        var events: [GhosttySurfaceHostEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    /// Strips the DEBUG-only throttled accessibility reads the session
    /// performs after output chunks, so ordering assertions stay exact in
    /// both build configurations.
    private func withoutAccessibilityReads(_ calls: [ScriptedSurfaceBackend.Call]) -> [ScriptedSurfaceBackend.Call] {
        calls.filter {
            if case .readText = $0 { return false }
            return true
        }
    }

    @Test func preservesSubmissionOrderAcrossCommandKinds() async {
        let backend = ScriptedSurfaceBackend()
        let (session, stream) = makeSession(backend: backend)

        for index in 0..<32 {
            session.submit(.output(Data("chunk-\(index)".utf8)))
        }
        session.submit(.bindingAction("scroll_to_bottom"))
        session.submit(.output(Data("tail".utf8)))
        session.shutdown()
        _ = await drain(stream)

        var expected: [ScriptedSurfaceBackend.Call] = (0..<32).map { .processOutput("chunk-\($0)") }
        expected.append(.bindingAction("scroll_to_bottom"))
        expected.append(.processOutput("tail"))
        expected.append(.free)
        #expect(withoutAccessibilityReads(backend.calls) == expected)
    }

    @Test func freesBackendExactlyOnceAfterDrainingQueuedWork() async {
        let backend = ScriptedSurfaceBackend()
        let (session, stream) = makeSession(backend: backend)

        session.submit(.output(Data("a".utf8)))
        session.shutdown()
        session.shutdown() // idempotent
        _ = await drain(stream)

        #expect(withoutAccessibilityReads(backend.calls) == [.processOutput("a"), .free])
    }

    @Test func dropsSubmissionsAfterShutdown() async {
        let backend = ScriptedSurfaceBackend()
        let (session, stream) = makeSession(backend: backend)

        session.shutdown()
        session.submit(.output(Data("late".utf8)))
        _ = await drain(stream)

        #expect(backend.calls == [.free])
    }

    @Test func emitsOutputAppliedPerChunkAndRenderCompleted() async {
        let backend = ScriptedSurfaceBackend()
        let (session, stream) = makeSession(backend: backend)

        session.submit(.output(Data("one".utf8)))
        session.submit(.output(Data("two".utf8)))
        session.submit(.render)
        session.shutdown()
        let events = await drain(stream)

        let outputApplied = events.filter {
            if case .outputApplied = $0 { return true }
            return false
        }
        let renders = events.filter {
            if case .renderCompleted = $0 { return true }
            return false
        }
        #expect(outputApplied.count == 2)
        #expect(renders.count == 1)
    }

    @Test func geometryFillsContainerWithoutPin() async {
        let backend = ScriptedSurfaceBackend(
            measuredSizes: [
                GhosttySurfaceMeasuredSize(columns: 100, rows: 40, pixelWidth: 1000, pixelHeight: 800),
            ]
        )
        let (session, stream) = makeSession(backend: backend)

        let request = GhosttySurfaceGeometryRequest(
            containerWidth: 500,
            containerHeight: 400,
            scale: 2,
            contentScaleToApply: 2,
            pin: nil,
            reassertNaturalSize: true
        )
        session.submit(.geometry(request))
        session.shutdown()
        let events = await drain(stream)

        guard case .geometryMeasured(let measurement)? = events.first else {
            Issue.record("expected a geometryMeasured event, got \(events)")
            return
        }
        #expect(measurement.request == request)
        #expect(measurement.natural.columns == 100)
        #expect(measurement.cellPixelWidth == 10)
        #expect(measurement.cellPixelHeight == 20)
        #expect(measurement.pinnedSize == nil)
        #expect(backend.calls.first == .setContentScale(2))
        #expect(backend.calls.contains(.setSize(1000, 800)))
    }

    @Test func geometryFitsPinnedGridSmallerThanContainer() async {
        let natural = GhosttySurfaceMeasuredSize(columns: 100, rows: 40, pixelWidth: 1000, pixelHeight: 800)
        let fitted = GhosttySurfaceMeasuredSize(columns: 50, rows: 20, pixelWidth: 500, pixelHeight: 400)
        let backend = ScriptedSurfaceBackend(
            measuredSizes: [natural, fitted],
            fallback: fitted
        )
        let (session, stream) = makeSession(backend: backend)

        let request = GhosttySurfaceGeometryRequest(
            containerWidth: 500,
            containerHeight: 400,
            scale: 2,
            contentScaleToApply: nil,
            pin: GhosttySurfaceGridPin(columns: 50, rows: 20),
            reassertNaturalSize: false
        )
        session.submit(.geometry(request))
        session.shutdown()
        let events = await drain(stream)

        guard case .geometryMeasured(let measurement)? = events.first else {
            Issue.record("expected a geometryMeasured event, got \(events)")
            return
        }
        // Pin fit: 50 cols × 10px = 500px wide, 20 rows × 20px = 400px high,
        // scale 2 → 250×200 points, well under the 500×400 container.
        #expect(measurement.pinnedSize == GhosttySurfacePinnedSize(width: 250, height: 200))
        // The fit pushed a second set_size for the pinned pixel box.
        #expect(backend.calls.contains(.setSize(500, 400)))
    }

    @Test func readTextRunsOnSessionAndReturnsBackendText() async {
        let backend = ScriptedSurfaceBackend()
        backend.scriptedText = "hello world"
        let (session, _) = makeSession(backend: backend)

        let text = await session.readText(.viewport)
        #expect(text == "hello world")
        #expect(backend.calls == [.readText(.viewport)])
        session.shutdown()
    }
}
