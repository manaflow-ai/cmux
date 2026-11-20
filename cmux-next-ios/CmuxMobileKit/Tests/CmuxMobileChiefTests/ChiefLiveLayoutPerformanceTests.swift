#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileChief

/// Copy this unchanged test to base and head and run on the same simulator:
/// CMUX_CHIEF_LIVE_PERF=1, filter ChiefLiveLayoutPerformanceTests.
/// Base also sets -D CMUX_CHIEF_LIVE_BASELINE: the adapter below reproduces
/// its original reply view because the extracted production view is new.
/// Measures synchronous main-thread layout time, excluding streaming waits.
/// Both revisions lay out every token: batching is an additional saving this
/// conservative layout measurement does not assume.
@Suite @MainActor struct ChiefLiveLayoutPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_CHIEF_LIVE_PERF"] == "1"))
    func longReplyLayoutPerThousandTokens() {
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.loadViewIfNeeded()
        let seed = String(repeating: "A long reply with ordinary words and a completed paragraph.\n", count: 800)
        var samples: [Double] = []
        var checksum: CGFloat = 0
        for pass in 0..<4 {
            var text = seed
            let start = ContinuousClock.now
            for token in 0..<1_000 {
                text += " word\(token)"
                let live = ChiefLive(key: "benchmark", text: text)
                let rendered = ChiefLiveBubble.replyText(live) ?? ""
                #if CMUX_CHIEF_LIVE_BASELINE
                host.rootView = AnyView(Text(rendered)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(8)
                    .truncationMode(.head)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(uiColor: .systemGray5), in: .rect(cornerRadius: 18, style: .continuous))
                    .frame(maxWidth: 300, alignment: .leading))
                #else
                host.rootView = AnyView(ChiefLiveReplyText(text: rendered))
                #endif
                checksum += host.sizeThatFits(in: CGSize(width: 300, height: 10_000)).height
            }
            let elapsed = start.duration(to: .now).components
            let ms = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            if pass > 0 { samples.append(ms) } // One warm-up, then three samples.
        }
        print("CHIEF_LIVE_LAYOUT main_thread_ms_per_1000_tokens=\(samples.sorted()[1]) samples=\(samples) checksum=\(checksum)")
        #expect(checksum > 0)
    }
}
#endif
