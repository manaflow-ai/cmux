import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
@testable import MessagesLabHome
@testable import MessagesLabSidebar
import Testing

/// Leo 2026-10-13 (cx-sya4n): Austin gets headaches from blinking and pulsing status lights.
/// Under macOS Reduce Motion nothing in cmux may loop: the shared status indicators (sidebar
/// rows, tabs, chrome spinners), the pane attention ring, and the vendored Home transcript and
/// conversation list (their typing dots breathed and pulsed forever whatever the setting said).
@MainActor @Suite(.serialized) struct ReduceMotionLoopTests {
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

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

    /// One workspace per indicator state, in a sidebar laid out in a window.
    static func sidebar(in window: NSWindow) -> SidebarView {
        let states: [StatusIndicatorState] = [.working(progress: nil), .busy(progress: nil), .paused(progress: nil), .waiting(kind: nil),
                                              .waiting(kind: .permission), .error, .success]
        let workspaces = states.enumerated().map { index, state in
            SidebarWorkspace(id: WorkspaceID("ws-\(index)"), title: "workspace \(index)", agentWorking: true, activity: state)
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    @Test(.enabled("indicators stop while their window is not on a screen") { await Self.hasDisplay() })
    func statusIndicatorsAndTheAttentionRingDoNotLoopUnderReduceMotion() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        let content = try #require(window.contentView)
        content.wantsLayer = true
        let sidebar = Self.sidebar(in: window)

        let spinner = StatusIndicatorView.spinner()
        spinner.frame = NSRect(x: 300, y: 20, width: 16, height: 16)
        content.addSubview(spinner)
        spinner.spin(true)

        var working = TabItem(id: CmuxNextTabs.TabID("t-working"), title: "claude")
        working.indicator = .working(progress: nil)
        var loading = TabItem(id: CmuxNextTabs.TabID("t-busy"), title: "page")
        loading.indicator = .busy(progress: nil)
        for (index, item) in [working, loading].enumerated() {
            let cell = TabCell(item: item)
            cell.layer.frame = CGRect(x: 260, y: 60 + CGFloat(index) * 40, width: 180, height: 32)
            content.layer?.addSublayer(cell.layer)
        }

        // The pane attention ring (PaneOverlayView) and the flash verb (PaneHandlers+Verbs).
        var attention = AttentionSettings()
        attention.blinkCount = AttentionSettings.blinkRange.upperBound
        for style in [AttentionStyle.blink, .pulse, .steady] {
            attention.style = style
            let ring = CALayer()
            if let animation = Motion.attentionAnimation(attention) { ring.add(animation, forKey: "attention") }
            content.layer?.addSublayer(ring)
        }
        let flash = CALayer()
        if let animation = Motion.flashAnimation() { flash.add(animation, forKey: "flash") }
        content.layer?.addSublayer(flash)

        content.layoutSubtreeIfNeeded()
        #expect(sidebar.list.rowViews.count >= 7)
        #expect(Self.loops(under: content.layer) == [])
    }

    /// The Home conversation list's typing bubble (MessagesLabSidebar) and the transcript's
    /// typing row (MessagesLabHome): still dots, no breathing, under Reduce Motion.
    @Test func homesTypingIndicatorsDoNotLoopUnderReduceMotion() {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        // The Home column hosts the vendored list; building it wires cmux's motion into it.
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
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
}
