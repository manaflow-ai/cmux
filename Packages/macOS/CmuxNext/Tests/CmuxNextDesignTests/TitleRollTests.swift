import AppKit
@testable import CmuxNextDesign
import Testing

/// A renamed title rolls as the agent chat's live line rolls a new tool call (Leo, 2026-11-08:
/// "when workspaces get renamed (esp by agents) it should have that same fade in animation that
/// the tool call situation has"): the old words leave on a copy above, the new rise in from below.
@MainActor @Suite(.serialized) struct TitleRollTests {
    private func title(_ string: String, in host: CALayer) -> ChromeTextLayer {
        let text = ChromeTextLayer()
        text.string = string
        text.frame = CGRect(x: 0, y: 0, width: 120, height: 16)
        host.addSublayer(text)
        return text
    }

    @Test func aRenameRollsTheOldWordsOutAndTheNewIn() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let host = CALayer()
        let text = title("Fix login", in: host)
        text.string = "Fix the login redirect"
        #expect(Motion.sidebar.rollTitle(text, from: "Fix login", flipped: true, in: nil))
        let out = host.sublayers?.compactMap { $0 as? ChromeTextLayer }.first { $0.name == MotionGate.rollOutName }
        #expect(out?.string == "Fix login")
        #expect(out?.bounds == text.bounds)
        #expect(out?.position == text.position)
        #expect(out?.animation(forKey: "opacity") != nil)
        #expect(out?.animation(forKey: "transform.translation.y") != nil)
        #expect(text.animation(forKey: "opacity") != nil)
        #expect(text.animation(forKey: "transform.translation.y") != nil)
        #expect(text.opacity == 1, "the new words land on the model's opacity")
        // In a flipped host the old words leave upward: toward smaller y.
        let travel = out?.animation(forKey: "transform.translation.y") as? CABasicAnimation
        #expect(((travel?.toValue as? CGFloat) ?? 0) < 0)
    }

    @Test func aHiddenTitleStaysHiddenThroughARename() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let host = CALayer()
        let text = title("Fix login", in: host)
        text.opacity = 0 // a pinned or narrow tab hides its title
        text.string = "Renamed"
        #expect(!Motion.tabs.rollTitle(text, from: "Fix login", flipped: true, in: nil))
        #expect(host.sublayers?.contains { $0.name == MotionGate.rollOutName } != true)
    }

    @Test func aSecondRenameReplacesTheFirstsOutgoingWords() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let host = CALayer()
        let text = title("One", in: host)
        text.string = "Two"
        Motion.sidebar.rollTitle(text, from: "One", flipped: true, in: nil)
        text.string = "Three"
        Motion.sidebar.rollTitle(text, from: "Two", flipped: true, in: nil)
        let outs = host.sublayers?.compactMap { $0 as? ChromeTextLayer }.filter { $0.name == MotionGate.rollOutName } ?? []
        #expect(outs.map(\.string) == ["Two"])
    }

    @Test func reduceMotionAndFirstNamesDoNotRoll() {
        let host = CALayer()
        let text = title("Fix login", in: host)
        text.string = "Renamed"
        Motion.reduceMotionOverride = true
        #expect(!Motion.sidebar.rollTitle(text, from: "Fix login", flipped: true, in: nil))
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        #expect(!Motion.sidebar.rollTitle(text, from: "", flipped: true, in: nil))
        #expect(!Motion.sidebar.rollTitle(text, from: "Renamed", flipped: true, in: nil))
        #expect(host.sublayers?.contains { $0.name == MotionGate.rollOutName } != true)
    }
}
