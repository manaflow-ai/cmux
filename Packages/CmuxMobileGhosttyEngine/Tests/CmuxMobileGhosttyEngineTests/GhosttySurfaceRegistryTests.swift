import Foundation
import Testing
@testable import CmuxMobileGhosttyEngine

@MainActor
@Suite struct GhosttySurfaceRegistryTests {
    private func makeRegisteredSurface(
        registry: GhosttySurfaceRegistry,
        identity: UInt,
        backend: ScriptedSurfaceBackend = ScriptedSurfaceBackend()
    ) -> (GhosttySurfaceSession, AsyncStream<GhosttySurfaceHostEvent>) {
        let (stream, continuation) = AsyncStream.makeStream(of: GhosttySurfaceHostEvent.self)
        let session = GhosttySurfaceSession(backend: backend, events: continuation)
        registry.register(identity: identity, session: session, events: continuation)
        return (session, stream)
    }

    @Test func routesTitleAndBellToTheSurfaceStream() async {
        let registry = GhosttySurfaceRegistry()
        let (session, stream) = makeRegisteredSurface(registry: registry, identity: 7)

        registry.dispatchTitleChanged(identity: 7, title: "vim")
        registry.dispatchBell(identity: 7)
        registry.dispatchFocusInput(identity: 7)
        session.shutdown()

        var titles: [String] = []
        var bells = 0
        var focusRequests = 0
        for await event in stream {
            switch event {
            case .titleChanged(let title): titles.append(title)
            case .bellRang: bells += 1
            case .focusInputRequested: focusRequests += 1
            default: break
            }
        }
        #expect(titles == ["vim"])
        #expect(bells == 1)
        #expect(focusRequests == 1)
        #expect(registry.title(identity: 7) == "vim")
    }

    @Test func unregisterStopsRoutingAndForgetsTitle() async {
        let registry = GhosttySurfaceRegistry()
        let (session, stream) = makeRegisteredSurface(registry: registry, identity: 9)

        registry.dispatchTitleChanged(identity: 9, title: "before")
        registry.unregister(identity: 9)
        registry.dispatchTitleChanged(identity: 9, title: "after")
        session.shutdown()

        var titles: [String] = []
        for await event in stream {
            if case .titleChanged(let title) = event { titles.append(title) }
        }
        #expect(titles == ["before"])
        #expect(registry.title(identity: 9) == nil)
    }

    @Test func snapshotWithoutOnScreenSurfacesSaysSo() async {
        let registry = GhosttySurfaceRegistry()
        let (session, _) = makeRegisteredSurface(registry: registry, identity: 3)
        // No snapshot-context provider installed → surface is "off screen".
        let snapshot = await registry.visibleTerminalSnapshot()
        #expect(snapshot == "===== visible terminal: (no on-screen surface) =====")
        session.shutdown()
    }

    @Test func snapshotPairsContextWithViewportText() async {
        let registry = GhosttySurfaceRegistry()
        let backend = ScriptedSurfaceBackend()
        backend.scriptedText = "prompt %"
        let (session, _) = makeRegisteredSurface(registry: registry, identity: 4, backend: backend)
        registry.setSnapshotContextProvider(identity: 4) {
            GhosttySurfaceSnapshotContext(gridDescription: "80x24", fontSize: 12)
        }

        let snapshot = await registry.visibleTerminalSnapshot()
        #expect(snapshot.contains("grid=80x24"))
        #expect(snapshot.contains("font=12"))
        #expect(snapshot.contains("prompt %"))
        session.shutdown()
    }
}
