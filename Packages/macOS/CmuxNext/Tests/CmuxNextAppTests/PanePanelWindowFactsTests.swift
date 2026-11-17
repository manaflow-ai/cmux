import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// What AppKit does with a panel that is a child window of a titled window, read on a real screen: a probe, not a
/// test of the product. It asserts nothing about AppKit. It writes each fact that it reads to
/// `pane-panel-facts.json` at the package's root (for `cmux-ci run --artifact`) and prints it.
///
/// It runs only on a display step. Each wait is a bounded number of passes of the main run loop over a state that
/// AppKit owns (the app is active, the window is miniaturized, the app is hidden, the window is in full screen); a
/// state that does not come is written as `false`, and the probe goes on.
@MainActor @Suite(.serialized, .closesItsWindows) struct PanePanelWindowFactsTests {
    /// A panel that can be key and is never main, as a floating pane's panel is; it counts its key changes.
    final class ProbePanel: NSPanel {
        var resigns = 0, becomes = 0
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func resignKey() {
            resigns += 1
            super.resignKey()
        }
        override func becomeKey() {
            becomes += 1
            super.becomeKey()
        }
    }

    /// A view that writes down each window that it moves to.
    final class MoveRecorder: NSView {
        var will: [String] = [], did: [String] = []
        var name: (NSWindow?) -> String = { _ in "?" }
        override var acceptsFirstResponder: Bool { true }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            will.append(name(newWindow))
            super.viewWillMove(toWindow: newWindow)
        }
        override func viewDidMoveToWindow() {
            did.append(name(window))
            super.viewDidMoveToWindow()
        }
    }

    nonisolated static var onDisplayStep: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CMUX_CI_DISPLAY_ROUTED"] == "1" || environment["CMUX_TEST_REQUIRE_GUI"] == "1"
    }

    /// Turns the main run loop until `done()`, at most `passes` passes of 50 ms.
    @discardableResult func wait(_ passes: Int = 100, until done: () -> Bool) -> Bool {
        for _ in 0..<passes where !done() { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
        return done()
    }

    /// A fixed number of passes of the main run loop, for a state that has no flag to read.
    func turn(_ passes: Int = 6) {
        for _ in 0..<passes { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
    }

    func text(_ rect: NSRect) -> String { "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))" }

    func panel(_ style: NSWindow.StyleMask, frame: NSRect, cycle: Bool = false) -> ProbePanel {
        let panel = ProbePanel(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .normal
        panel.collectionBehavior = cycle ? [.fullScreenAuxiliary] : [.fullScreenAuxiliary, .ignoresCycle]
        if style.contains(.titled) {
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        } else {
            panel.hasShadow = true
        }
        return panel
    }

    @Test(.enabled(if: PanePanelWindowFactsTests.onDisplayStep))
    func readTheFacts() throws {
        var facts: [String: String] = [:]
        var order: [String] = []
        func note(_ key: String, _ value: Any) {
            facts[key] = "\(value)"
            order.append(key)
            print("PANE-PANEL-FACT \(key) = \(value)")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        note("a.app_active", wait { app.isActive })
        note("a.os", ProcessInfo.processInfo.operatingSystemVersionString)
        note("a.screens", NSScreen.screens.map { text($0.frame) }.joined(separator: " | "))
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first, "a display step has a screen")
        let visible = screen.visibleFrame
        note("a.visible_frame", text(visible))

        let titled: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let parent = NSWindow(contentRect: NSRect(x: visible.minX + 120, y: visible.minY + 120, width: 700, height: 460), styleMask: titled,
                              backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: visible.minX + 40, y: visible.minY + 40, width: 360, height: 240), styleMask: titled,
                             backing: .buffered, defer: false)
        parent.title = "parent"
        other.title = "other"
        var made: [NSWindow] = [parent, other]
        defer { for window in made.reversed() { window.parent?.removeChildWindow(window); window.closeAfterTest() } }
        var names: [Int: String] = [:]
        func name(_ window: NSWindow?) -> String { window.map { names[$0.windowNumber] ?? "unknown(\($0.className))" } ?? "nil" }
        func stack() -> String {
            NSWindow.windowNumbers(options: [])?.compactMap { names[$0.intValue] }.joined(separator: " > ") ?? "none"
        }
        func keyAndMain() -> String { "key=\(name(app.keyWindow)) main=\(name(app.mainWindow))" }

        other.makeKeyAndOrderFront(nil)
        parent.makeKeyAndOrderFront(nil)
        names[parent.windowNumber] = "parent"
        names[other.windowNumber] = "other"
        note("a.parent_key", wait { parent.isKeyWindow })

        // B. The style: a titled panel with a hidden title bar, and a borderless one with a shadow.
        let start = NSRect(x: parent.frame.minX + 150, y: parent.frame.minY + 100, width: 320, height: 220)
        let pane = panel([.titled, .fullSizeContentView, .resizable], frame: start)
        let plain = panel([.borderless, .resizable], frame: start.offsetBy(dx: 60, dy: -40))
        made += [pane, plain]
        parent.addChildWindow(pane, ordered: .above)
        names[pane.windowNumber] = "panel"
        pane.makeKeyAndOrderFront(nil)
        note("b.panel_key", wait { pane.isKeyWindow })
        note("b.key_and_main", keyAndMain())
        note("b.parent_is_main", parent.isMainWindow)
        note("b.titled.has_shadow", pane.hasShadow)
        note("b.titled.corner_radius", pane.frameCornerRadius)
        note("b.parent.corner_radius", parent.frameCornerRadius)
        note("b.titled.frame", text(pane.frame))
        note("b.titled.content_layout_rect", text(pane.contentLayoutRect))
        note("b.titled.title_bar_height", pane.frame.height - pane.contentLayoutRect.height)
        note("b.titled.content_view_frame", text(pane.contentView?.frame ?? .zero))
        note("b.titled.min_size", "\(pane.minSize.width)x\(pane.minSize.height)")
        parent.addChildWindow(plain, ordered: .above)
        names[plain.windowNumber] = "plain"
        note("b.borderless.has_shadow", plain.hasShadow)
        let rawRadius: Any = plain.responds(to: NSSelectorFromString("_cornerRadius")) ? (plain.value(forKey: "_cornerRadius") ?? "nil") : "none"
        note("b.borderless.raw_corner_radius", rawRadius)
        note("b.borderless.frame", text(plain.frame))
        note("b.stack_two_children", stack())
        parent.removeChildWindow(plain)
        plain.orderOut(nil)

        // C. A child of the panel against another child of the parent that comes later.
        let grand = panel([.borderless], frame: NSRect(x: start.minX + 20, y: start.minY + 20, width: 120, height: 80))
        let sibling = panel([.borderless], frame: NSRect(x: start.minX + 60, y: start.minY + 40, width: 120, height: 80))
        made += [grand, sibling]
        pane.addChildWindow(grand, ordered: .above)
        names[grand.windowNumber] = "child_of_panel"
        parent.addChildWindow(sibling, ordered: .above)
        names[sibling.windowNumber] = "later_child_of_parent"
        turn()
        note("c.stack_child_of_child", stack())
        parent.removeChildWindow(sibling)
        sibling.orderOut(nil)
        turn()
        note("c.stack_after_sibling_left", stack())
        pane.removeChildWindow(grand)
        grand.orderOut(nil)

        // D. A key child through a remove and an add (a new order of the children).
        pane.makeKey()
        wait { pane.isKeyWindow }
        pane.resigns = 0
        pane.becomes = 0
        parent.removeChildWindow(pane)
        note("d.after_remove", "panel_key=\(pane.isKeyWindow) visible=\(pane.isVisible) \(keyAndMain())")
        parent.addChildWindow(pane, ordered: .above)
        note("d.after_add_same_turn", "panel_key=\(pane.isKeyWindow) visible=\(pane.isVisible) resigns=\(pane.resigns) becomes=\(pane.becomes)")
        turn()
        note("d.after_add_later", "panel_key=\(pane.isKeyWindow) resigns=\(pane.resigns) becomes=\(pane.becomes) \(keyAndMain())")

        // E. The app's own cycle of its windows, from a key panel.
        let cycles = ["_cycleWindowsReversed:", "_cycleWindows:"].map(NSSelectorFromString).filter { app.responds(to: $0) }
        note("e.cycle_selector", cycles.first.map(NSStringFromSelector) ?? "none")
        if let cycle = cycles.first {
            pane.makeKey()
            wait { pane.isKeyWindow }
            var seen: [String] = []
            for _ in 0..<3 {
                app.perform(cycle, with: nil)
                turn()
                seen.append(keyAndMain())
            }
            note("e.ignores_cycle.three_cycles", seen.joined(separator: " ; "))
            parent.makeKeyAndOrderFront(nil)
            pane.collectionBehavior = [.fullScreenAuxiliary]
            pane.makeKey()
            wait { pane.isKeyWindow }
            seen = []
            for _ in 0..<3 {
                app.perform(cycle, with: nil)
                turn()
                seen.append(keyAndMain())
            }
            note("e.in_cycle.three_cycles", seen.joined(separator: " ; "))
            pane.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        }
        parent.makeKeyAndOrderFront(nil)
        pane.makeKey()
        wait { pane.isKeyWindow }
        note("e.stack_after_cycles", stack())

        // F. The parent moves and changes its size.
        func delta(_ before: NSRect, _ after: NSRect) -> String {
            "dx=\(Int(after.minX - before.minX)) dy=\(Int(after.minY - before.minY)) dw=\(Int(after.width - before.width)) dh=\(Int(after.height - before.height))"
        }
        var before = pane.frame
        parent.setFrameOrigin(NSPoint(x: parent.frame.minX + 50, y: parent.frame.minY + 30))
        note("f.parent_moved_50_30.panel_same_turn", delta(before, pane.frame))
        turn()
        note("f.parent_moved_50_30.panel_later", delta(before, pane.frame))
        before = pane.frame
        var frame = parent.frame
        frame.size.width += 100
        frame.size.height += 60
        parent.setFrame(frame, display: true)
        turn()
        note("f.parent_grew_from_bottom_left.panel", delta(before, pane.frame))
        before = pane.frame
        frame = parent.frame
        frame.origin.x += 40
        frame.origin.y += 30
        frame.size.width -= 40
        frame.size.height -= 30
        parent.setFrame(frame, display: true)
        turn()
        note("f.parent_shrank_from_top_right_corner_fixed.panel", delta(before, pane.frame))

        // G. A panel out of its parent and off the display.
        let home = pane.frame
        var wanted = NSRect(x: parent.frame.maxX + 60, y: parent.frame.minY, width: 320, height: 220)
        pane.setFrame(wanted, display: true)
        turn()
        note("g.right_of_parent", "wanted=\(text(wanted)) got=\(text(pane.frame)) visible=\(pane.isVisible)")
        wanted = NSRect(x: screen.frame.maxX - 60, y: visible.minY + 100, width: 320, height: 220)
        pane.setFrame(wanted, display: true)
        turn()
        note("g.partly_off_the_right_edge", "wanted=\(text(wanted)) got=\(text(pane.frame)) screen=\(pane.screen.map { text($0.frame) } ?? "nil")")
        wanted = NSRect(x: visible.minX + 300, y: screen.frame.maxY - 100, width: 320, height: 220)
        pane.setFrame(wanted, display: true)
        turn()
        note("g.above_the_menu_bar", "wanted=\(text(wanted)) got=\(text(pane.frame))")
        wanted = NSRect(x: screen.frame.maxX + 400, y: visible.minY + 100, width: 320, height: 220)
        pane.setFrame(wanted, display: true)
        turn()
        note("g.wholly_off_each_display", "wanted=\(text(wanted)) got=\(text(pane.frame)) visible=\(pane.isVisible) screen=\(pane.screen.map { text($0.frame) } ?? "nil")")
        pane.setFrame(home, display: true)
        turn()

        // K. A view that moves from the parent's content into the panel's, by one addSubview.
        let recorder = MoveRecorder(frame: NSRect(x: 10, y: 10, width: 100, height: 60))
        recorder.wantsLayer = true
        recorder.name = { name($0) }
        parent.contentView?.addSubview(recorder)
        parent.makeKey()
        wait { parent.isKeyWindow }
        note("k.first_responder_taken", parent.makeFirstResponder(recorder))
        recorder.will = []
        recorder.did = []
        pane.contentView?.addSubview(recorder)
        note("k.one_add_subview.will_move", recorder.will.joined(separator: ","))
        note("k.one_add_subview.did_move", recorder.did.joined(separator: ","))
        note("k.first_responder_after", "parent_has_it=\(parent.firstResponder === recorder) panel_has_it=\(pane.firstResponder === recorder)")
        note("k.layer_kept", recorder.layer != nil)
        recorder.will = []
        recorder.did = []
        parent.contentView?.addSubview(recorder)
        note("k.back.did_move", recorder.did.joined(separator: ","))

        // M. A key panel that leaves and comes back (a hide and a show of one floating pane).
        pane.makeKey()
        wait { pane.isKeyWindow }
        pane.orderOut(nil)
        turn()
        note("m.order_out_while_child", "panel_visible=\(pane.isVisible) parent_visible=\(parent.isVisible) still_child=\(parent.childWindows?.contains(pane) ?? false) \(keyAndMain())")
        parent.orderFront(nil)
        turn()
        note("m.parent_ordered_front_after", "panel_visible=\(pane.isVisible) \(keyAndMain())")
        parent.removeChildWindow(pane)
        pane.orderOut(nil)
        parent.makeKeyAndOrderFront(nil)
        turn()
        note("m.removed_then_order_out", "panel_visible=\(pane.isVisible) \(keyAndMain())")
        parent.addChildWindow(pane, ordered: .above)
        turn()
        note("m.added_again", "panel_visible=\(pane.isVisible) frame_kept=\(pane.frame == home) \(keyAndMain())")
        pane.makeKey()
        wait { pane.isKeyWindow }

        // H. The parent is miniaturized with a key child.
        before = pane.frame
        parent.miniaturize(nil)
        note("h.miniaturized", wait { parent.isMiniaturized })
        turn()
        note("h.while_miniaturized", "panel_visible=\(pane.isVisible) panel_key=\(pane.isKeyWindow) still_child=\(parent.childWindows?.contains(pane) ?? false) \(keyAndMain())")
        parent.deminiaturize(nil)
        note("h.deminiaturized", wait { !parent.isMiniaturized })
        turn(20)
        note("h.after", "panel_visible=\(pane.isVisible) \(delta(before, pane.frame)) \(keyAndMain()) stack=\(stack())")

        // I. The app is hidden and shown again.
        parent.makeKeyAndOrderFront(nil)
        pane.makeKey()
        wait { pane.isKeyWindow }
        before = pane.frame
        app.hide(nil)
        note("i.hidden", wait { app.isHidden })
        turn()
        note("i.while_hidden", "panel_visible=\(pane.isVisible) parent_visible=\(parent.isVisible)")
        app.unhide(nil)
        app.activate(ignoringOtherApps: true)
        note("i.unhidden", wait { !app.isHidden && app.isActive })
        turn(20)
        note("i.after", "panel_visible=\(pane.isVisible) \(delta(before, pane.frame)) \(keyAndMain()) stack=\(stack())")

        // J. The parent goes to full screen and back, with the panel partly out of it.
        parent.makeKeyAndOrderFront(nil)
        pane.setFrame(NSRect(x: parent.frame.maxX - 100, y: parent.frame.minY + 60, width: 320, height: 220), display: true)
        turn()
        before = pane.frame
        let parentBefore = parent.frame
        parent.collectionBehavior.insert(.fullScreenPrimary)
        parent.toggleFullScreen(nil)
        let entered = wait(200) { parent.styleMask.contains(.fullScreen) }
        note("j.entered_full_screen", entered)
        turn(30)
        let child = parent.childWindows?.contains(pane) ?? false
        note("j.in_full_screen", "parent=\(text(parent.frame)) panel=\(text(pane.frame)) panel_visible=\(pane.isVisible) "
            + "panel_on_active_space=\(pane.isOnActiveSpace) still_child=\(child) \(keyAndMain())")
        if entered {
            parent.toggleFullScreen(nil)
            note("j.left_full_screen", wait(200) { !parent.styleMask.contains(.fullScreen) })
            turn(30)
        }
        note("j.after", "parent \(delta(parentBefore, parent.frame)) ; panel \(delta(before, pane.frame)) panel_visible=\(pane.isVisible) \(keyAndMain())")

        // The facts, in the order of the reads.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let rows = order.map { ["fact": $0, "value": facts[$0] ?? ""] }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
        try data.write(to: root.appending(path: "pane-panel-facts.json"))
        #expect(!rows.isEmpty)
    }
}
