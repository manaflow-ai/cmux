import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextHome
@testable import MessagesLabHome
@testable import MessagesLabSidebar
import Testing

/// Leo 2026-10-13 (cx-sya4n): blinking and pulsing lights give a teammate headaches. Under macOS
/// Reduce Motion nothing in cmux may loop. The vendored Home transcript and conversation list
/// cannot see `Motion`, and their typing dots breathed and pulsed forever whatever the setting said.
@MainActor @Suite(.serialized) struct ReduceMotionLoopTests {
    /// Every animation on `layer` and the layers under it (masks included) that repeats.
    static func loops(under layer: CALayer?, path: String = "") -> [String] {
        guard let layer else { return [] }
        let here = path + "/" + (layer.name ?? String(describing: type(of: layer)))
        let own = (layer.animationKeys() ?? []).compactMap { key -> String? in
            guard let animation = layer.animation(forKey: key), repeats(animation) else { return nil }
            return "\(here) [\(key)]"
        }
        return own + ((layer.sublayers ?? []) + [layer.mask].compactMap { $0 }).flatMap { loops(under: $0, path: here) }
    }

    static func repeats(_ animation: CAAnimation) -> Bool {
        if animation.repeatCount >= .greatestFiniteMagnitude || animation.repeatDuration > 0 { return true }
        if let group = animation as? CAAnimationGroup { return (group.animations ?? []).contains(where: repeats) }
        return false
    }

    /// The Home conversation list's typing bubble (MessagesLabSidebar) and the transcript's
    /// typing row (MessagesLabHome): still dots, no breathing, under Reduce Motion.
    @Test func homesTypingIndicatorsDoNotLoopUnderReduceMotion() {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        // The Home column hosts the vendored list; building it wires cmux's motion into it.
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        #expect(CmuxSidebarView.reduceMotionOverride == true)
        #expect(MessagesLabHomeView.reduceMotionOverride == true)
        home.list.show([CmuxSidebarEntry(id: "chief", title: "Chief", people: [], preview: "", previewSender: nil, lastAt: Date(),
                                         unreadCount: 0, pinned: false, typing: true)], pinned: [])
        home.layoutSubtreeIfNeeded()
        #expect(Self.loops(under: home.layer) == [])

        let bubble = SidebarTypingLayer()
        bubble.animate()
        #expect(Self.loops(under: bubble) == [], "the list's typing bubble pulses")

        let cell = RowCell(frame: CGRect(x: 0, y: 0, width: 400, height: 40))
        cell.startTypingDots(begin: CACurrentMediaTime())
        cell.startTypingBreath(insert: CACurrentMediaTime())
        let typing = cell.dots + cell.typingDiscs + [cell.typingContainer, cell.typingClip]
        #expect(typing.flatMap { Self.loops(under: $0) } == [], "the transcript's typing row breathes or its dots pulse")
    }

    /// The pins follow `Motion.reduceMotionOverride` after the mirror is installed.
    @Test func homesPinsFollowMotionsOverride() {
        _ = HomeSidebarView(frame: .zero)
        Motion.reduceMotionOverride = true
        #expect(CmuxSidebarView.reduceMotionOverride == true)
        Motion.reduceMotionOverride = nil
        #expect(CmuxSidebarView.reduceMotionOverride == nil)
        #expect(MessagesLabHomeView.reduceMotionOverride == nil)
    }
}
