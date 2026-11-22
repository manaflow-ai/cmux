#if os(iOS)
@testable import CmuxMobileAgentChat
import SwiftUI
import Testing
import UIKit

/// SUB-11's tall row: a subagent transcript's tall answer is measured once per text, width and
/// text size, off the body pass, and its pinned height is the height the transcript draws.
@MainActor
@Suite struct SubagentRowHeightsTests {
    /// A pasted log as long as the rig's (240 lines, about 15,000 pt at the phone's width).
    static let log = MockStressContent.giantPrompt(1)
    static let key = SubagentRowHeights.Key(width: 362, size: .large)

    static func rows(_ answer: String = log) -> [TurnRow] {
        [.message(id: "m0", markdown: "Short answer"), .message(id: "tall", markdown: answer),
         .tool(ACPToolCall(id: "c1", title: "Read a.swift", kind: .read, status: .completed))]
    }

    @Test func aTallAnswerIsMeasuredOncePerTextWidthAndSize() {
        let heights = SubagentRowHeights()
        #expect(SubagentRowHeights.isTall(Self.log))
        heights.measure(Self.rows(), key: Self.key, live: nil)
        #expect(heights.measures == 1, "only the tall answer is measured")
        for _ in 0..<5 { heights.measure(Self.rows(), key: Self.key, live: nil) }
        #expect(heights.measures == 1, "measured again with nothing changed: \(heights.measures)")
        #expect(heights.height("tall", markdown: Self.log, key: Self.key) != nil)
        #expect(heights.height("m0", markdown: "Short answer", key: Self.key) == nil, "a short answer is not pinned")

        let landscape = SubagentRowHeights.Key(width: 800, size: .large)
        heights.measure(Self.rows(), key: landscape, live: nil)
        #expect(heights.measures == 2, "a new width measures again")
        let larger = SubagentRowHeights.Key(width: 800, size: .xxxLarge)
        heights.measure(Self.rows(), key: larger, live: nil)
        #expect(heights.measures == 3, "a new text size measures again")
        heights.measure(Self.rows(Self.log + "\nmore"), key: larger, live: nil)
        #expect(heights.measures == 4, "new text measures again")
        #expect(heights.height("tall", markdown: Self.log, key: larger) == nil, "the old text's height is not used for the new")

        heights.measure(Self.rows(Self.log + "\nlive"), key: larger, live: "tall")
        #expect(heights.measures == 4, "the streaming answer is never measured (its text changes per token)")
        print("CMUX_TALL_ROW_MEASURE \(heights.measures) measures, \(Int(heights.measureSeconds * 1000)) ms on the main thread")
    }

    final class Box { var height: CGFloat = 0 }

    /// The answer as the transcript lays it out in a window, read from its laid-out frame.
    static func laidOut(_ markdown: String, key: SubagentRowHeights.Key) -> CGFloat {
        let box = Box()
        let content = SubagentRowHeights.answer(markdown, key: key)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { box.height = $0 }
        let root = ScrollView { content }.frame(width: key.width)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: key.width, height: 800))
        window.rootViewController = host
        window.isHidden = false
        for _ in 0..<5 {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        window.isHidden = true
        return box.height
    }

    @Test(arguments: [SubagentRowHeights.Key(width: 362, size: .large), SubagentRowHeights.Key(width: 800, size: .large),
                      SubagentRowHeights.Key(width: 362, size: .xxxLarge)])
    func thePinnedHeightIsTheDrawnHeight(key: SubagentRowHeights.Key) {
        let measured = SubagentRowHeights.drawnSize(Self.log, key: key).height
        let drawn = Self.laidOut(Self.log, key: key)
        print("CMUX_TALL_ROW_HEIGHT width \(key.width) size \(key.size): measured \(measured) pt, drawn \(drawn) pt")
        #expect(drawn > 2000, "the log is tall (\(drawn) pt)")
        #expect(abs(measured - drawn) <= 0.5, "measured \(measured) pt, drawn \(drawn) pt")
    }
}
#endif
