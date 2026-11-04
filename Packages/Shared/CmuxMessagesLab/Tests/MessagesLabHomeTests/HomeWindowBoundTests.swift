import AppKit
@testable import CmuxHomeCore
import Foundation
@testable import MessagesLabHome
import Testing

/// The Mac Chief chat (the Home transcript over HomeStore), open and resting at the newest
/// message, keeps its loaded window bounded while replies keep arriving: nobody scrolls a
/// Chief chat left open, so the bound must not wait for a scroll.
@Suite(.serialized) @MainActor struct HomeWindowBoundTests {
    /// The bound the Home transcript keeps (HomeStore.windowTrimThreshold and windowKeepCount),
    /// as numbers so this test also builds, and fails, on a commit without the bound.
    static let trimThreshold = 1500
    static let keepCount = 1000
    static let batches = 32
    static let perBatch = 50

    /// The regression: 1,600 replies to an open chat leave at most the trim threshold loaded.
    @Test func liveRepliesWhileRestingAtTheNewestKeepTheWindowBounded() async throws {
        let rig = try await HomeChatRig()
        defer { rig.stop() }
        let last = try await flood(rig) { _, _ in }
        let loaded = rig.store.transcript(for: HomeChatRig.conversation).count
        #expect(loaded <= Self.trimThreshold, "loaded \(loaded) after \(last) replies")
        #expect(rig.store.transcript(for: HomeChatRig.conversation).last?.plainText == last)
        #expect(rig.view.controller.store?.state.ui.scroll.pinnedToBottom == true)
    }

    /// The video proof: one frame of the real view per batch with the loaded count drawn on it,
    /// written to `artifacts/chief-window-mac/frames.json` (base64 PNGs) at the repository root.
    /// It records whatever happens and asserts nothing, so it also runs (and returns its frames)
    /// on a commit without the bound.
    @Test func recordsTheLoadedWindowAsRepliesArrive() async throws {
        let rig = try await HomeChatRig(width: 600, height: 760)
        defer { rig.stop() }
        var frames: [[String: Any]] = []
        func shoot(_ arrived: Int, _ loaded: Int) {
            guard let png = HomeWindowBoundTests.frame(rig.window, arrived: arrived, loaded: loaded) else { return }
            frames.append(["arrived": arrived, "loaded": loaded, "png": png.base64EncodedString()])
        }
        shoot(0, rig.store.transcript(for: HomeChatRig.conversation).count)
        _ = try await flood(rig) { arrived, loaded in shoot(arrived, loaded) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("artifacts/chief-window-mac")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["frames": frames])
        try data.write(to: dir.appendingPathComponent("frames.json"))
        print("CHIEF_WINDOW_MAC frames=\(frames.count) file=\(dir.path)/frames.json")
    }

    /// Posts the replies in batches; after each, two display frames (the arrival, then the
    /// bound the view schedules for the next frame). Returns the newest reply's text.
    private func flood(_ rig: HomeChatRig, each: (Int, Int) -> Void) async throws -> String {
        var text = ""
        var arrived = 0
        for batch in 1...Self.batches {
            for _ in 0..<Self.perBatch {
                arrived += 1
                text = "\(arrived). Chief: the fleet build passed and the tag is published."
                #expect(await rig.source.post(text, from: rig.chief, in: HomeChatRig.conversation, key: .make()) != nil)
            }
            let newest = text
            await HomeChatRig.until { rig.store.transcript(for: HomeChatRig.conversation).last?.plainText == newest }
            rig.frame()
            rig.frame()
            let loaded = rig.store.transcript(for: HomeChatRig.conversation).count
            print("CHIEF_WINDOW_MAC batch=\(batch) arrived=\(arrived) loaded=\(loaded)")
            each(arrived, loaded)
        }
        return text
    }

    private static func frame(_ window: NSWindow, arrived: Int, loaded: Int) -> Data? {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let size = view.bounds.size
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        rep.draw(in: NSRect(origin: .zero, size: size))
        let banner = NSRect(x: 0, y: 0, width: size.width, height: 96)
        (loaded > Self.trimThreshold ? NSColor.systemRed : NSColor.systemGreen).withAlphaComponent(0.92).setFill()
        banner.fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = "Mac Chief chat: replies arrived \(arrived)\nMessages loaded: \(loaded)  (bound: above \(Self.trimThreshold) trims to \(Self.keepCount))"
        (text as NSString).draw(in: banner.insetBy(dx: 12, dy: 18), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
