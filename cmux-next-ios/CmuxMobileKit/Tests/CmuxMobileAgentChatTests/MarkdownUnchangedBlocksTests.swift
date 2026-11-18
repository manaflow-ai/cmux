#if os(iOS)
@testable import CmuxMobileAgentChat
import CmuxMobileMarkdown
import SwiftUI
import Testing
import UIKit

/// Leo, 2026-11-18: "we draw the visible area, right?" A streamed token changes a long message's
/// last block only, so it redraws that block, never every block above it: the same count at
/// 1,000 and 10,000 blocks (`MarkdownBlockView.bodyCount`, a DEBUG test hook).
@MainActor @Suite(.serialized) struct MarkdownUnchangedBlocksTests {
    func settle(_ window: UIWindow) async {
        for _ in 0 ..< 5 {
            window.rootViewController?.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    @Test(arguments: [1_000, 10_000])
    func aStreamedTokenRedrawsTheTailBlockOnly(blocks n: Int) async {
        let text = (0..<n).map { "Paragraph \($0) of a long answer." }.joined(separator: "\n\n")
        let host = UIHostingController(rootView: StreamingMarkdown(markdown: text, isStreaming: true, animatesBlocks: false))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await settle(window)
        #expect(MarkdownBlockView.bodyCount > 0, "the message never drew")
        MarkdownBlockView.bodyCount = 0
        host.rootView = StreamingMarkdown(markdown: text + " More", isStreaming: true, animatesBlocks: false)
        await settle(window)
        print("VISIBLE_ONLY markdown blocks=\(n) block_bodies_after_one_token=\(MarkdownBlockView.bodyCount)")
        #expect(MarkdownBlockView.bodyCount <= 2, "one token redrew \(MarkdownBlockView.bodyCount) of \(n) blocks")
    }
}
#endif
