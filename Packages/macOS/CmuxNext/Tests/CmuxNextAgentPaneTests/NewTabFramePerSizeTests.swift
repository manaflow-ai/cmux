import AppKit
@testable import CmuxNextAgentPane
import Testing

/// Cmd-N from a split workspace (Leo 2026-10-20: "the layout shifts"): the prewarmed page waits at
/// a split pane's size, and the new workspace's one pane covers it with the New Tab frame at the
/// whole area's size. A split pane's frame never replaces that one, and no frame of another size
/// stands in for it.
@MainActor
struct NewTabFramePerSizeTests {
    private static let whole = CGSize(width: 1000, height: 800), split = CGSize(width: 500, height: 400)

    @Test func aSplitPanesFrameKeepsTheWholeAreasFrame() {
        let frames = AgentPaneNewTabFrame(), wide = NSImage(size: Self.whole), narrow = NSImage(size: Self.split)
        frames.store(wide, size: Self.whole, appearance: .darkAqua, generation: frames.generation)
        frames.store(narrow, size: Self.split, appearance: .darkAqua, generation: frames.generation)
        #expect(frames.image(size: Self.whole, appearance: .darkAqua) === wide)
        #expect(frames.image(size: Self.split, appearance: .darkAqua) === narrow)
        #expect(frames.image(size: CGSize(width: 700, height: 800), appearance: .darkAqua) == nil)
        #expect(frames.image(size: Self.whole, appearance: .aqua) == nil)
    }

    @Test func aNewFrameAtASizeReplacesItsOldOneAndTheOldestSizeGoes() {
        let frames = AgentPaneNewTabFrame(), first = NSImage(size: Self.whole), again = NSImage(size: Self.whole)
        frames.store(first, size: Self.whole, appearance: nil, generation: frames.generation)
        frames.store(again, size: Self.whole, appearance: nil, generation: frames.generation)
        #expect(frames.image(size: Self.whole, appearance: nil) === again)
        for width in 1...AgentPaneNewTabFrame.sizes {
            frames.store(NSImage(), size: CGSize(width: width, height: 1), appearance: nil, generation: frames.generation)
        }
        #expect(frames.image(size: Self.whole, appearance: nil) == nil)
        #expect(frames.image(size: CGSize(width: 1, height: 1), appearance: nil) != nil)
    }
}
