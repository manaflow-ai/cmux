import CmuxHomeCore
import CmuxHomeRender
import CoreGraphics
import Foundation
import Observation
import os
import Testing
@testable import MessagesLabHome

/// A renderer that draws a fixed-size solid image and counts its calls.
final class FakeDiagrams: HomeDiagramRendering, @unchecked Sendable {
    // @unchecked Sendable: the counters are touched only by the serialized tests below.
    var layouts = 0
    var images = 0
    let size = CGSize(width: 150, height: 90)

    func layout(mermaid source: String, maxWidth: CGFloat) -> CGSize? {
        layouts += 1
        return source.hasPrefix("graph") ? CGSize(width: min(size.width, maxWidth), height: size.height) : nil
    }

    func image(mermaid source: String, maxWidth: CGFloat, style: HomeDiagramStyle, scale: CGFloat) -> CGImage? {
        images += 1
        guard let natural = layout(mermaid: source, maxWidth: maxWidth) else { return nil }
        let w = Int(natural.width * scale), h = Int(natural.height * scale)
        guard let ctx = CGContext.ownedBitmap(width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// A renderer whose engine loads only in ``prewarm()``; it counts the warm checks and the layouts
/// asked of it while cold (each would load the engine on the caller's thread), and reports each
/// prewarm, with whether it ran on the main thread, on ``warmed``.
final class ColdDiagrams: HomeDiagramRendering {
    let warmed: AsyncStream<Bool>
    private let signal: AsyncStream<Bool>.Continuation
    private let counts = OSAllocatedUnfairLock(initialState: Counts())

    private struct Counts {
        var loaded = false
        var warmChecks = 0
        var coldLayouts = 0
    }

    init() {
        let made = AsyncStream<Bool>.makeStream()
        warmed = made.stream
        signal = made.continuation
    }

    /// How often the transcript asked whether to warm (``needsPrewarm``).
    var warmChecks: Int { counts.withLock { $0.warmChecks } }
    /// Layouts asked before the engine loaded.
    var coldLayouts: Int { counts.withLock { $0.coldLayouts } }

    var isReady: Bool { counts.withLock { $0.loaded } }
    var needsPrewarm: Bool {
        counts.withLock { counts in
            counts.warmChecks += 1
            return !counts.loaded
        }
    }

    func prewarm() {
        counts.withLock { $0.loaded = true }
        signal.yield(Thread.isMainThread)
    }

    func layout(mermaid source: String, maxWidth: CGFloat) -> CGSize? {
        counts.withLock { if !$0.loaded { $0.coldLayouts += 1 } }
        return source.hasPrefix("graph") ? CGSize(width: 150, height: 90) : nil
    }

    func image(mermaid source: String, maxWidth: CGFloat, style: HomeDiagramStyle, scale: CGFloat) -> CGImage? { nil }
}

/// Home chat draws ```mermaid fences as diagram bubbles (user msg 2481 follow-up): the text
/// around a fence stays text, a source the renderer refuses stays as written, and the bubble's
/// size is known before its pixels.
@Suite(.serialized) struct HomeDiagramMappingTests {
    let fake = FakeDiagrams()

    init() {
        HomeMarkdownPolicy.install()
        CustomRows.unregister(HomeDiagramRowProvider.kind)
        CustomRows.register(HomeDiagramRowProvider(renderer: fake))
    }

    func mapped(_ text: String, markdown: Bool = true) -> [Part] {
        defer { CustomRows.unregister(HomeDiagramRowProvider.kind) }
        return HomeMapping.parts(.text(text), markdown: markdown)
    }

    static func isDiagram(_ part: Part) -> String? {
        guard case .custom(let c) = part, c.kind == HomeDiagramRowProvider.kind else { return nil }
        return HomeDiagramRowProvider.source(c)
    }

    /// The engine loads only for a transcript that holds a Mermaid fence; a fence still
    /// streaming in warms a cold renderer off the main thread, so the closed fence does not wait for it.
    @MainActor @Test(.timeLimit(.minutes(1))) func aStreamingFenceWarmsAColdRenderer() async {
        let cold = ColdDiagrams()
        CustomRows.unregister(HomeDiagramRowProvider.kind)
        CustomRows.register(HomeDiagramRowProvider(renderer: cold))
        var warmed = cold.warmed.makeAsyncIterator()
        let parts = mapped("Here is the flow:\n```mermaid\ngraph TD\nA-->")
        #expect(parts.allSatisfy { Self.isDiagram($0) == nil }, "an open fence stays text")
        #expect(await warmed.next() == false, "the engine loads off the main thread")
    }

    /// p07-memory-082 review: a closed fence over a cold engine never loads it on the mapping's
    /// thread (the main thread in the app): the fence maps as text, the engine loads off it, and the
    /// fence maps as a diagram once it is loaded.
    @MainActor @Test(.timeLimit(.minutes(1))) func aClosedFenceOnAColdRendererLoadsItOffTheCallingThread() async {
        let cold = ColdDiagrams()
        let provider = HomeDiagramRowProvider(renderer: cold)
        CustomRows.unregister(HomeDiagramRowProvider.kind)
        CustomRows.register(provider)
        var warmed = cold.warmed.makeAsyncIterator()
        let loads = provider.readiness.loads
        let text = "Here is the flow:\n```mermaid\ngraph TD\nA-->B\n```\nDone."
        let parts = mapped(text)
        #expect(parts.allSatisfy { Self.isDiagram($0) == nil }, "a cold engine maps the fence as text")
        #expect(cold.coldLayouts == 0, "no layout on the calling thread: it would load the engine there")
        #expect(await warmed.next() == false, "the engine loads off the main thread")
        if provider.readiness.loads == loads {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                withObservationTracking { _ = provider.readiness.loads } onChange: { done.resume() }
            }
        }
        CustomRows.register(provider)
        #expect(mapped(text).contains { Self.isDiagram($0) == "graph TD\nA-->B" }, "the loaded engine draws the fence")
    }

    /// p07-memory-082 review: the word in prose is no diagram, so it never warms the engine (it would
    /// load it again right after a critical release dropped it).
    @Test(arguments: ["I cannot draw a mermaid diagram here.", "Mermaid is a sea creature.\n```swift\nlet x = 1\n```"])
    func proseThatMentionsMermaidDoesNotWarm(_ text: String) {
        let cold = ColdDiagrams()
        CustomRows.unregister(HomeDiagramRowProvider.kind)
        CustomRows.register(HomeDiagramRowProvider(renderer: cold))
        #expect(mapped(text).allSatisfy { Self.isDiagram($0) == nil })
        #expect(cold.warmChecks == 0, "no warm for a text with no Mermaid fence")
        #expect(cold.coldLayouts == 0)
    }

    /// The window that shows a fence mapped as text maps again when the engine loads (HomeProjection.observeDiagrams).
    @MainActor @Test(.timeLimit(.minutes(1))) func aPostedFenceBecomesADiagramWhenTheEngineLoads() async throws {
        let cold = ColdDiagrams()
        CustomRows.unregister(HomeDiagramRowProvider.kind)
        let rig = try await HomeChatRig(history: 4, diagrams: cold)
        defer {
            rig.stop()
            CustomRows.unregister(HomeDiagramRowProvider.kind)
        }
        var warmed = cold.warmed.makeAsyncIterator()
        func drawn() -> Int {
            rig.view.controller.store?.state.conversation.messages.reduce(0) { count, message in
                count + message.parts.filter { Self.isDiagram($0) != nil }.count
            } ?? 0
        }
        #expect(await rig.post("\(HomeChatRig.tag) flow:\n```mermaid\ngraph TD\nA-->B\n```", key: IdempotencyKey("run_diagram")))
        rig.frame()
        #expect(await warmed.next() == false, "the engine loads off the main thread")
        await HomeChatRig.until { drawn() == 1 }
        #expect(drawn() == 1, "the loaded engine's diagram replaced the text")
        #expect(cold.coldLayouts == 0, "the mapping never laid a fence out on the cold engine")
    }

    @Test func aFenceBetweenTextIsItsOwnBubble() {
        let parts = mapped("Here is the flow:\n```mermaid\ngraph TD\nA-->B\n```\nDone.")
        #expect(parts.count == 3)
        #expect(parts.first?.plainText == "Here is the flow:")
        #expect(parts.dropFirst().first.flatMap(Self.isDiagram) == "graph TD\nA-->B")
        #expect(parts.last?.plainText == "Done.")
    }

    @Test func peoplesTextSplitsToo() {
        let parts = mapped("```mermaid\ngraph LR\nX-->Y\n```", markdown: false)
        #expect(parts.count == 1)
        #expect(parts.first.flatMap(Self.isDiagram) == "graph LR\nX-->Y")
    }

    @Test func aRefusedSourceStaysAsWritten() {
        let text = "Before\n```mermaid\nnot a diagram\n```\nAfter"
        let parts = mapped(text, markdown: false)
        #expect(parts.allSatisfy { Self.isDiagram($0) == nil })
        #expect(parts.compactMap(\.plainText).joined(separator: "\n").contains("not a diagram"))
        #expect(parts.compactMap(\.plainText).joined(separator: "\n").contains("```mermaid"))
    }

    @Test func aRefusedFenceNextToADiagramJoinsTheText() {
        let parts = mapped("```mermaid\nbad\n```\n```mermaid\ngraph TD\nA-->B\n```", markdown: false)
        #expect(parts.count == 2)
        #expect(parts.first?.plainText?.contains("bad") == true)
        #expect(parts.last.flatMap(Self.isDiagram) == "graph TD\nA-->B")
    }

    @Test func withoutARendererFencesStayText() {
        CustomRows.unregister(HomeDiagramRowProvider.kind)
        let parts = HomeMapping.parts(.text("```mermaid\ngraph TD\nA-->B\n```"), markdown: false)
        #expect(parts.allSatisfy { Self.isDiagram($0) == nil })
    }

    @Test func copyAndVoiceOverReadTheSource() throws {
        let part = try #require(mapped("```mermaid\ngraph TD\nA-->B\n```").first)
        guard case .custom(let c) = part else { Issue.record("not a custom part"); return }
        CustomRows.register(HomeDiagramRowProvider(renderer: fake))
        defer { CustomRows.unregister(HomeDiagramRowProvider.kind) }
        #expect(CustomRows.plainText(c) == "graph TD\nA-->B")
    }

    @Test func theSizeIsKnownBeforeTheImageAndDrawingKeepsIt() throws {
        let provider = HomeDiagramRowProvider(renderer: fake)
        let part = try #require(provider.part("graph TD\nA-->B"))
        guard case .custom(let c) = part else { Issue.record("not a custom part"); return }
        let size = provider.measure(c, maxWidth: 400)
        let pad = HomeDiagramRowProvider.padding
        #expect(size == CGSize(width: fake.size.width + 2 * pad, height: fake.size.height + 2 * pad))
        #expect(fake.images == 0, "measuring draws no pixels")

        let scale = 2
        let ctx = try #require(CGContext.ownedBitmap(width: Int(size.width) * scale, height: Int(size.height) * scale, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        provider.drawRow(c, in: ctx, rect: CGRect(origin: .zero, size: size), context: CustomRowDrawContext(outgoing: false, isDark: true, elevated: false))
        #expect(fake.images == 1)
        #expect(provider.measure(c, maxWidth: 400) == size, "the size does not change once the image exists")
        let pixels = try #require(ctx.makeImage()?.dataProvider?.data as Data?)
        let bytesPerRow = try #require(ctx.makeImage()?.bytesPerRow)
        let center = (Int(size.height) * scale / 2) * bytesPerRow + (Int(size.width) * scale / 2) * 4
        #expect(pixels[center] > 230 && pixels[center + 1] < 40 && pixels[center + 3] > 230, "the image is drawn inside the bubble")
        let corner = 2 * bytesPerRow + 2 * 4
        #expect(pixels[corner + 3] == 0, "the padding stays clear")
    }

    @Test func aTallDiagramScalesDownToTheCap() {
        let fitted = HomeDiagramRowProvider.fit(CGSize(width: 100, height: 2000), width: 300, height: HomeDiagramRowProvider.maxHeight)
        #expect(fitted.height == HomeDiagramRowProvider.maxHeight)
        #expect(abs(fitted.width - 100 * HomeDiagramRowProvider.maxHeight / 2000) < 0.001)
    }
}
