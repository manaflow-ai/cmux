import AppKit
import Dispatch
import Testing
@testable import MessagesLabHome

/// RowBitmaps draws up to three rows at once off the main thread, and a
/// window resize re-renders every visible row at the new width. An agent's
/// reply with inline code (the Chief writes `leave it empty`, `workspace-2`)
/// must build its attributed text on all of those threads at once: every code
/// run draws monospaced and no render throws (Lawrence's crashes on
/// 2026-10-08: "addAttribute:value:range:: nil value" in
/// TextLayout.attributed while he resized the Chief chat).
@Suite struct ConcurrentRowTextTests {
    @Test func codeRunsDrawMonospacedOnManyRenderThreadsAtOnce() throws {
        let (shown, runs) = HomeMarkdown.render("Run `gh` now")
        // Built without line breaking: Core Text's line caches keep the font they measured alive for a
        // while, which hides the race this test reproduces (RowBitmaps' rows drop theirs when drawn).
        let tl = TextLayout(text: shown, runs: runs, lines: [], width: 0)
        let code = try #require(tl.runs.first { $0.style == ["code"] })
        #expect(tl.text == "Run gh now")
        let lock = NSLock()
        var notMonospaced = 0
        // 8 threads: a resize burst over RowBitmaps' queue plus the loader's prerender.
        // Short rows, so the threads make and drop the code font as often as a real burst does.
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<50000 {
                autoreleasepool {
                    let font = tl.attributed(color: .white, linkColor: .white).attribute(.font, at: code.start, effectiveRange: nil) as? NSFont
                    if font?.isFixedPitch != true { lock.lock(); notMonospaced += 1; lock.unlock() }
                }
            }
        }
        #expect(notMonospaced == 0)
    }
}
