import AppKit
import Dispatch
import Testing
@testable import MessagesLabHome

/// Crash program class (cx-qpqs): AppKit font factories annotated nonnull
/// return nil when threads make and drop the last instance at once, and the
/// row renderers run on several threads. HomeFonts holds one font per size
/// and weight for the process; a Markdown run's bold or italic face is held
/// too, and a run with no such face gets no font attribute (never a nil).
@Suite struct HomeFontsTests {
    @Test func aSystemFontIsHeldOncePerSizeAndWeight() {
        let a = HomeFonts.system(ofSize: 10, weight: .semibold)
        let b = HomeFonts.system(ofSize: 10, weight: .semibold)
        #expect(a === b)
        #expect(a.pointSize == 10)
        #expect(HomeFonts.system(ofSize: 10) !== a)
        // A size computed from a frame lands on the half point.
        #expect(HomeFonts.system(ofSize: 10.2, weight: .heavy) === HomeFonts.system(ofSize: 10.1, weight: .heavy))
        #expect(HomeFonts.monospaced(ofSize: 12).isFixedPitch)
    }

    @Test func boldAndItalicRunsDrawTheirFaceOnManyRenderThreadsAtOnce() throws {
        let (shown, runs) = HomeMarkdown.render("Run **bold** and *slanted* now")
        let tl = TextLayout(text: shown, runs: runs, lines: [], width: 0)
        let bold = try #require(tl.runs.first { $0.style?.contains("bold") == true })
        let italic = try #require(tl.runs.first { $0.style?.contains("italic") == true })
        let lock = NSLock()
        var wrong = 0
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<20000 {
                autoreleasepool {
                    let text = tl.attributed(color: .white, linkColor: .white)
                    let b = text.attribute(.font, at: bold.start, effectiveRange: nil) as? NSFont
                    let i = text.attribute(.font, at: italic.start, effectiveRange: nil) as? NSFont
                    let ok = b?.fontDescriptor.symbolicTraits.contains(.bold) == true
                        && i?.fontDescriptor.symbolicTraits.contains(.italic) == true
                    if !ok { lock.lock(); wrong += 1; lock.unlock() }
                }
            }
        }
        #expect(wrong == 0)
    }
}
