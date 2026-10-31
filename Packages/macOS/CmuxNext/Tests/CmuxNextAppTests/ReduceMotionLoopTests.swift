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

    /// Reduce Motion turning on while the list's typing bubble pulses stops the pulse (the list
    /// hears the change; nothing waits for the next row update).
    @Test func reduceMotionTurningOnStopsAPulsingBubble() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        home.list.wantsLayer = true
        let bubble = SidebarTypingLayer()
        home.list.layer?.addSublayer(bubble)
        bubble.animate()
        #expect(Self.loops(under: bubble) != [], "the bubble should pulse before Reduce Motion")
        Motion.reduceMotionOverride = true
        #expect(Self.loops(under: bubble) == [], "the bubble keeps pulsing after Reduce Motion turned on")
        Motion.reduceMotionOverride = false
        #expect(Self.loops(under: bubble) != [], "the bubble does not pulse again after Reduce Motion turned off")
    }

    /// Reduce Motion turning on while a transcript typing row runs stills its dots and stops its breath.
    @Test func reduceMotionTurningOnStillsARunningTypingRow() {
        MessagesLabHomeView.reduceMotionOverride = false
        defer { MessagesLabHomeView.reduceMotionOverride = nil }
        let cell = RowCell(frame: CGRect(x: 0, y: 0, width: 400, height: 40))
        cell.startTypingDots(begin: CACurrentMediaTime())
        cell.startTypingBreath(insert: CACurrentMediaTime())
        let typing = cell.dots + cell.typingDiscs + [cell.typingContainer, cell.typingClip]
        #expect(typing.flatMap { Self.loops(under: $0) } != [], "the typing row should loop before Reduce Motion")
        MessagesLabHomeView.reduceMotionOverride = true
        cell.applyReduceMotion()
        #expect(typing.flatMap { Self.loops(under: $0) } == [], "the typing row keeps looping after Reduce Motion turned on")
        // A later breath start (the row's next update) stops a breath too, not only skips it.
        MessagesLabHomeView.reduceMotionOverride = false
        cell.startTypingBreath(insert: CACurrentMediaTime())
        MessagesLabHomeView.reduceMotionOverride = true
        cell.startTypingBreath(insert: CACurrentMediaTime())
        // Hoisted: #expect wraps a rethrowing call in a throwing closure ("call can throw").
        let breathLoops: [String] = [cell.typingContainer, cell.typingClip].flatMap { Self.loops(under: $0) }
        #expect(breathLoops == [])
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

    /// Calm mode (`ui.calm`) reduces motion everywhere `Motion` reaches; Home's vendored views
    /// only see their pins, so the mirror pins them on while it is on and gives them back after.
    @Test func calmModePinsHomesReduceMotion() {
        _ = HomeSidebarView(frame: .zero)
        let design = DesignSettings.shared
        let saved = design.calmMode
        defer { design.calmMode = saved }
        Motion.reduceMotionOverride = nil
        design.calmMode = .calm
        #expect(MessagesLabHomeView.reduceMotionOverride == true)
        #expect(CmuxSidebarView.reduceMotionOverride == true)
        design.calmMode = .still
        #expect(MessagesLabHomeView.reduceMotionOverride == true)
        // A test's pin still wins over calm mode.
        Motion.reduceMotionOverride = false
        #expect(MessagesLabHomeView.reduceMotionOverride == false)
        Motion.reduceMotionOverride = nil
        design.calmMode = .off
        #expect(MessagesLabHomeView.reduceMotionOverride == nil)
        #expect(CmuxSidebarView.reduceMotionOverride == nil)
    }
}
