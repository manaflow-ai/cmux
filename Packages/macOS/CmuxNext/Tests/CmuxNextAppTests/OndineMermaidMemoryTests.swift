import CmuxHomeRender
import CmuxNextCompat
@testable import CmuxNextHome
import CmuxNextWakeupsTestSupport
import CoreGraphics
import Testing

/// Home chat's Mermaid renderer as a memory consumer: its render and image caches
/// are bounded, a lower limit trims the images but keeps the working set, critical pressure drops the
/// JavaScriptCore context, and so does an idle deadline; the next layout loads it again and gives the
/// same size.
@Suite struct OndineMermaidMemoryTests {
    static let script = OndineMermaidRendererTests.script
    static let style = OndineMermaidRendererTests.dark
    static let flowchart = "flowchart TD\n  A[Start] --> B{Is it?}\n  B -->|Yes| C[OK]\n  B -->|No| D[End]"

    static func source(_ index: Int) -> String {
        "graph TD\n  A\(index)[Node \(index)] --> B\(index)[Next]"
    }

    static func bytes(_ image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    @Test(.timeLimit(.minutes(2))) func aThousandDistinctSourcesKeepTheCachesUnderTheirCaps() throws {
        let cap = 2 << 20
        let renderer = OndineMermaidRenderer(script: Self.script, imageBytes: cap, clock: ManualClock())
        var drawn = 0
        for index in 0..<1_000 {
            let image = try #require(renderer.image(mermaid: Self.source(index), maxWidth: 338, style: Self.style, scale: 2))
            drawn += Self.bytes(image)
            #expect(renderer.cacheSizes.imageBytes <= cap)
        }
        #expect(drawn > 4 * cap, "the sources drew far more than the cap holds")
        #expect(renderer.cacheSizes.imageBytes > 0)
        #expect(renderer.cacheSizes.renders <= OndineMermaidRenderer.renderEntries)
    }

    @MainActor private final class RecordingRegistry: MemoryConsumerRegistry {
        private(set) var names: [String] = []
        private(set) var traits: [MemoryConsumerTraits] = []

        func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
            names.append(entry.name)
            traits.append(entry.traits)
        }
    }

    @MainActor @Test func theAppsRendererRegistersOnlyWithTheCoordinator() throws {
        let resources = OndineMermaidRendererTests.repoRoot.appending(path: "Resources")
        let registry = RecordingRegistry()
        let renderer = try #require(OndineMermaidRenderer.bundled(memory: registry, appResources: resources))
        #expect(registry.names == ["home-diagrams"])
        #expect(registry.traits.first?.isManaged == true)
        #expect(registry.traits.first?.retention == .lossless)
        #expect(!renderer.hasContext, "made before any diagram, it holds no engine")
        #expect(!renderer.prewarmsAtInstall, "it loads for the first Mermaid fence")
        let kept = try #require(OndineMermaidRenderer.bundled(memory: nil, appResources: resources))
        #expect(kept.prewarmsAtInstall, "with the feature off it loads at install, as before")
        #expect(registry.names.count == 1)
    }

    @Test func theEngineLoadsOnlyForADiagramOrAPrewarm() throws {
        let renderer = OndineMermaidRenderer(script: Self.script, clock: ManualClock())
        #expect(!renderer.hasContext, "a Home with no diagram holds no engine")
        #expect(!renderer.isReady, "a layout now would load the engine first")
        #expect(renderer.needsPrewarm)
        renderer.prewarm()
        #expect(renderer.hasContext)
        #expect(renderer.isReady)
        #expect(!renderer.needsPrewarm)
        _ = renderer.releaseMemory(downTo: MemoryLimit(percent: 1))
        #expect(renderer.isReady, "a warning keeps the engine")
        _ = renderer.releaseMemory(downTo: .criticalThreshold)
        #expect(!renderer.isReady)
        #expect(renderer.needsPrewarm, "a released engine warms again once the limit allows it")
        #expect(renderer.layout(mermaid: Self.flowchart, maxWidth: 338) != nil)
        #expect(renderer.hasContext)
        #expect(renderer.isReady)
    }

    /// p07-memory-082 review: while the limit is critical nothing warms the engine again; only a diagram
    /// a row measures or draws loads it.
    @Test func aCriticalLimitRefusesThePrewarm() throws {
        let renderer = OndineMermaidRenderer(script: Self.script, clock: ManualClock())
        renderer.prewarm()
        #expect(renderer.hasContext)
        _ = renderer.updateMemoryLimit(.criticalThreshold)
        _ = renderer.releaseMemory(downTo: .criticalThreshold)
        #expect(!renderer.hasContext)
        #expect(!renderer.needsPrewarm, "critical: no warm")
        renderer.prewarm()
        #expect(!renderer.hasContext, "critical: a prewarm does nothing")
        _ = renderer.updateMemoryLimit(.default)
        #expect(renderer.needsPrewarm)
        renderer.prewarm()
        #expect(renderer.hasContext)
    }

    @Test func aNewLimitFreesNothing() throws {
        let renderer = OndineMermaidRenderer(script: Self.script, clock: ManualClock())
        _ = try #require(renderer.image(mermaid: Self.flowchart, maxWidth: 338, style: Self.style, scale: 1))
        let before = try #require(renderer.updateMemoryLimit(.default))
        #expect(renderer.updateMemoryLimit(.criticalThreshold) == before)
        #expect(renderer.hasContext)
    }

    @Test func aLowerLimitTrimsTheImagesButKeepsTheWorkingSetAndTheContext() throws {
        let clock = ManualClock()
        let renderer = OndineMermaidRenderer(script: Self.script, imageBytes: 1 << 20, clock: clock)
        for index in 0..<3 {
            _ = try #require(renderer.image(mermaid: Self.source(index), maxWidth: 338, style: Self.style, scale: 1))
        }
        clock.advance(by: .seconds(3))
        let shown = try #require(renderer.image(mermaid: Self.source(3), maxWidth: 338, style: Self.style, scale: 1))
        let renders = renderer.cacheSizes.renders

        _ = renderer.releaseMemory(downTo: MemoryLimit(percent: 1))
        #expect(renderer.cacheSizes.imageBytes == Self.bytes(shown), "only the image drawn in the last 2 s stays")
        #expect(renderer.cacheSizes.renders == renders, "a warning keeps the renders")
        #expect(renderer.hasContext, "a warning keeps the context")
    }

    @Test func criticalDropsTheContextAndTheNextLayoutGivesTheSameSize() throws {
        let clock = ManualClock()
        let renderer = OndineMermaidRenderer(script: Self.script, clock: clock)
        let size = try #require(renderer.layout(mermaid: Self.flowchart, maxWidth: 338))
        _ = try #require(renderer.image(mermaid: Self.flowchart, maxWidth: 338, style: Self.style, scale: 2))
        #expect(renderer.hasContext)
        clock.advance(by: .seconds(3))

        let usage = renderer.releaseMemory(downTo: .criticalThreshold)
        #expect(!renderer.hasContext, "critical pressure drops the JavaScriptCore context")
        #expect(usage == .empty, "nothing was used in the last 2 s")

        #expect(renderer.layout(mermaid: Self.flowchart, maxWidth: 338) == size, "the next layout loads Ondine again")
        #expect(renderer.hasContext)
    }

    @Test func criticalKeepsTheWorkingSetsRenders() throws {
        let renderer = OndineMermaidRenderer(script: Self.script, clock: ManualClock())
        let size = try #require(renderer.layout(mermaid: Self.flowchart, maxWidth: 338))
        _ = renderer.releaseMemory(downTo: .criticalThreshold)
        #expect(!renderer.hasContext)
        #expect(renderer.cacheSizes.renders == 1, "a render used in the last 2 s stays")
        #expect(renderer.layout(mermaid: Self.flowchart, maxWidth: 338) == size)
        #expect(!renderer.hasContext, "a kept render needs no context")
    }

    @Test(.timeLimit(.minutes(1))) func tenMinutesWithNoDiagramShownDropTheContext() async throws {
        let clock = ManualClock()
        let (released, signal) = AsyncStream<Void>.makeStream()
        let renderer = OndineMermaidRenderer(script: Self.script, imageBytes: OndineMermaidRenderer.imageBytes,
                                             idleRelease: OndineMermaidRenderer.idleRelease, clock: clock,
                                             contextReleased: { signal.yield() })
        var releases = released.makeAsyncIterator()
        let size = try #require(renderer.layout(mermaid: Self.flowchart, maxWidth: 338))
        try await clock.waitForSleeper()
        #expect(clock.sleeperCount == 1, "one deadline, no timer")

        clock.advance(by: .seconds(300))
        _ = try #require(renderer.image(mermaid: Self.flowchart, maxWidth: 338, style: Self.style, scale: 1))
        clock.advance(by: .seconds(300))
        try await clock.waitForSleeper()
        #expect(renderer.hasContext, "a diagram was shown 5 min ago: the deadline moved")

        clock.advance(by: .seconds(300))
        _ = await releases.next()
        #expect(!renderer.hasContext)
        #expect(clock.sleeperCount == 0, "nothing is armed while the context is gone")

        #expect(renderer.layout(mermaid: "graph LR\n  X --> Y", maxWidth: 338) != nil, "a new diagram loads Ondine again")
        #expect(renderer.hasContext)
        #expect(renderer.layout(mermaid: Self.flowchart, maxWidth: 338) == size)
    }
}
