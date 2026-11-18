#if os(iOS)
@testable import CmuxMobileAgentChat
import CmuxMobileMarkdown
import SwiftUI
import Testing
import UIKit

/// Leo, 2026-11-18: "we draw the visible area, right?" A long message in a scroll view builds the
/// blocks on screen (and the lazy stack's overscan), not all of them: the same count at 1,000 and
/// 10,000 blocks (`MarkdownBlockView.bodyCount`, a DEBUG test hook).
@MainActor @Suite(.serialized) struct MarkdownLazyBlocksTests {
    func settle(_ window: UIWindow) async {
        for _ in 0 ..< 5 {
            window.rootViewController?.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    func message(_ n: Int) -> String {
        (0..<n).map { "Paragraph \($0) of a long answer." }.joined(separator: "\n\n")
    }

    /// Block bodies run to show `root` on an iPhone-sized window.
    func blocksBuilt(_ root: some View) async -> Int {
        MarkdownBlockView.bodyCount = 0
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await settle(window)
        return MarkdownBlockView.bodyCount
    }

    /// The subagent transcript's shape: a scroll view, a lazy stack of rows, the message one row.
    @Test func aLongMessageInATranscriptBuildsTheBlocksOnScreen() async {
        var built: [Int: Int] = [:]
        for n in [1_000, 10_000] {
            let text = message(n)
            built[n] = await blocksBuilt(ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text("Subagent of Chief")
                    StreamingMarkdown(markdown: text, isStreaming: false, animatesBlocks: false)
                }
                .padding(.horizontal, 20)
            })
            print("VISIBLE_ONLY markdown_transcript blocks=\(n) block_bodies_built=\(built[n] ?? -1)")
        }
        let small = built[1_000] ?? 0, large = built[10_000] ?? 0
        #expect(small > 0, "the message never drew")
        // About 26 paragraphs fill 874 pt; the rest is the lazy stack's overscan.
        #expect(large <= 120, "built \(large) of 10,000 blocks")
        #expect(Double(abs(large - small)) <= 0.1 * Double(max(small, 1)), "built \(small) at 1,000 and \(large) at 10,000")
    }

    /// A message that is the scroll view's content on its own.
    @Test func aLongMessageAloneInAScrollViewBuildsTheBlocksOnScreen() async {
        let built = await blocksBuilt(ScrollView { MarkdownView(markdown: message(10_000)) })
        print("VISIBLE_ONLY markdown_scroll blocks=10000 block_bodies_built=\(built)")
        #expect(built > 0 && built <= 120, "built \(built) of 10,000 blocks")
    }
}
#endif
