import AppKit
import CmuxNextDesign
@testable import CmuxNextDaemon
import CmuxNextHome
@testable import CmuxNextHomeEngine
import CmuxNextTestSupport
import Foundation
import Testing
import UniformTypeIdentifiers

/// The picture of the Chief Settings card's Reactions block (a416), light and dark side by side, in
/// `.build/chief-reactions-panel.png` of the package (a fleet step returns it with `--artifact`). It checks
/// only that both drew; the picture is for people.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeChiefReactionRowsCaptureTests {
    func render(_ appearance: NSAppearance.Name) async throws -> CGImage? {
        let (_, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: CapturedChief(writes: continuation))
        view.appearance = NSAppearance(named: appearance)
        // The room's theme draws the card, as in the app (an appearance alone left the theme dark).
        let scope = HomeChiefReactionRowsLayoutTests.scope(dark: appearance == .darkAqua)
        scope.root(view)
        await view.refresh().value
        // The picture shows the whole block: the Classifier disclosure open.
        view.reactionRows.showsClassifier = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: HomeChiefSettingsView.width, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        window.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        defer { window.close() }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        let dark = appearance == .darkAqua
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            scope.perform { Palette.pageBackground }.setFill()
            view.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        return rep.cgImage
    }

    @Test func theReactionsBlockInLightAndDark() async throws {
        let light = try #require(try await render(.aqua))
        let dark = try #require(try await render(.darkAqua))
        let gap = 24
        guard let ctx = CGContext(data: nil, width: light.width + gap + dark.width, height: max(light.height, dark.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { Issue.record("no context"); return }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.draw(light, in: CGRect(x: 0, y: ctx.height - light.height, width: light.width, height: light.height))
        ctx.draw(dark, in: CGRect(x: light.width + gap, y: ctx.height - dark.height, width: dark.width, height: dark.height))
        let image = try #require(ctx.makeImage())
        // The package directory: this file is Tests/CmuxNextAppTests/<name>.swift.
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/chief-reactions-panel.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}

/// A Chief on Claude with the classifier defaults and a model of its own.
private struct CapturedChief: HomeChiefEngineSource {
    let writes: AsyncStream<[String: String?]>.Continuation
    var isLocal: Bool { true }
    var place: String? { nil }

    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        var snapshot = HomeChiefSnapshot(harness: "claude", model: nil, effort: nil, avatar: "C", turns: [])
        var engine = ChiefEngineReport.Engine(harness: "claude", model: "claude-opus-5-5", effort: "high")
        engine.classifierHarness = "claude"
        engine.classifierModel = "claude-haiku-5-5"
        engine.classifierPrompt = ""
        engine.reactionsCanWake = true
        snapshot.effective = engine
        return snapshot
    }

    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        writes.yield(fields)
        return try await read()
    }
}
