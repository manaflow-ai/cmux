import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The Home composer's send button (user, 2026-10-20: "I want there to be a send button that I can
/// click in the iMessage UI ... if there are multiple lines in the input, this is still handled
/// extremely well"). The real view over a real `HomeStore` on the mock owner, in an offscreen
/// window; text goes in through the field's `insertText` (the path a key takes). The button is found
/// by its accessibility identifier, so these tests read only what VoiceOver and the pointer see.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HomeComposerSendButtonTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")
    static let identifier = "cmux.home.composer.send"

    struct Harness {
        let store: HomeStore
        let window: NSWindow
        let view: MessagesLabHomeView
        let field: NSTextView
    }

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("the condition never held"); return }
            await Task.yield()
        }
    }

    private func makeHarness() async throws -> Harness {
        // Animations are not what these tests check: the button is placed at once.
        MessagesLabHomeView.reduceMotionOverride = true
        let options = MockHomeSource.Options(chiefHistory: 20, latency: .zero, replyDelay: .seconds(3600))
        let store = HomeStore(source: MockHomeSource(options: options))
        store.start()
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake())
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        view.projection.refresh()
        view.layoutSubtreeIfNeeded()
        let maybeField = view.controller.demo?.compose.textView.view
        try #require(maybeField != nil)
        let field = maybeField!
        return Harness(store: store, window: window, view: view, field: field)
    }

    private func close(_ h: Harness) {
        h.view.stop(); h.window.close(); h.store.stop()
        MessagesLabHomeView.reduceMotionOverride = nil
    }

    /// The send button's accessibility element, found by its identifier among every view's
    /// accessibility children (the button is a layer of the compose bar's controls
    /// view, its element the view's child only while it shows); nil when none shows it.
    private static func find(_ root: NSView) -> NSAccessibilityElement? {
        var views: [NSView] = [root]
        while let v = views.popLast() {
            for case let e as NSAccessibilityElement in v.accessibilityChildren() ?? [] where e.accessibilityIdentifier() == identifier {
                return e
            }
            views += v.subviews
        }
        return nil
    }

    /// The button the pointer sees: the compose bar's controls view takes a click at its centre.
    private static func takesClick(_ h: Harness) -> Bool {
        let host = h.view.controller.host
        let f = host.sendButton.frame
        let hit = host.hitTest(host.convert(CGPoint(x: f.midX, y: f.midY), to: host.superview))
        return hit === host.composeChrome
    }

    private func type(_ h: Harness, _ text: String) async {
        h.field.insertText(text, replacementRange: h.field.selectedRange())
        for _ in 0..<8 { await Task.yield() }
        h.window.contentView?.layoutSubtreeIfNeeded()
    }

    private func clear(_ h: Harness) async {
        h.field.selectAll(nil)
        h.field.deleteBackward(nil)
        for _ in 0..<8 { await Task.yield() }
        h.window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Shown means: an accessibility element and it takes the pointer at its centre.
    private static func shown(_ h: Harness) -> Bool {
        find(h.view) != nil && takesClick(h)
    }

    @Test func theButtonAppearsOnlyWithText() async throws {
        let h = try await makeHarness()
        defer { close(h) }
        // Values only in the expectations: Swift Testing reflects a captured view deeply (and traps on its pasteboard).
        let emptyShown = Self.shown(h)
        #expect(!emptyShown, "an empty field shows the voice glyph, not the send button")
        await type(h, "hi")
        let typedShown = Self.shown(h)
        #expect(typedShown, "typed text shows the send button")
        let found = Self.find(h.view)
        try #require(found != nil, "the composer has a send button")
        let button = found!
        let isButton = button.accessibilityRole() == .button
        let labelled = button.accessibilityLabel()?.isEmpty == false
        let size = h.view.controller.host.sendButton.frame.size
        #expect(isButton)
        #expect(labelled)
        #expect(size.width >= 28 && size.height >= 28, "hit target at least 28 pt")
        await clear(h)
        let clearedShown = Self.shown(h)
        #expect(!clearedShown, "an emptied field hides it again")
    }

    @Test func aClickSendsExactlyLikeReturn() async throws {
        let h = try await makeHarness()
        defer { close(h) }
        await type(h, "hello from the button")
        let found = Self.find(h.view)
        try #require(found != nil)
        let button = found!
        let pressed = button.accessibilityPerformPress()
        #expect(pressed)
        await until {
            h.store.transcript(for: Self.conversation).contains { $0.parts == [.text("hello from the button")] }
        }
        let emptied = h.field.string.isEmpty
        #expect(emptied, "the field empties after the send, as after Return")
        h.window.contentView?.layoutSubtreeIfNeeded()
        let stillShown = Self.shown(h)
        #expect(!stillShown)
    }

    @Test func spacesOnlyShowADisabledButtonThatSendsNothing() async throws {
        let h = try await makeHarness()
        defer { close(h) }
        let before = h.store.transcript(for: Self.conversation).count
        await type(h, "   ")
        let found = Self.find(h.view)
        try #require(found != nil)
        let button = found!
        let enabled = button.isAccessibilityEnabled()
        #expect(!enabled)
        _ = button.accessibilityPerformPress()
        for _ in 0..<20 { await Task.yield() }
        let after = h.store.transcript(for: Self.conversation).count
        let text = h.field.string
        #expect(after == before)
        #expect(text == "   ", "nothing to send: the text stays")
    }

    /// Lawrence 2026-10-23: "make right and bottom padding the same". The drawn disc (24 pt in the
    /// 28 pt hit target) sat 5.5 pt from the field's right edge and 3.5 pt from its bottom. Measured
    /// in the real view, in the host's coordinates, for a one-line and a many-line draft.
    @Test func theDiscHasTheSameGapToTheFieldsRightAndBottomEdges() async throws {
        let h = try await makeHarness()
        defer { close(h) }
        let maybeCompose = h.view.controller.demo?.compose
        try #require(maybeCompose != nil)
        let compose = maybeCompose!
        let button = h.view.controller.host.sendButton
        for text in ["a", "\nline two\nline three\nline four"] {
            await type(h, text)
            let field = compose.fieldRect
            let disc = button.discFrame
            let right = field.maxX - disc.maxX, bottom = field.maxY - disc.maxY
            #expect(abs(right - bottom) < 0.25, "right gap \(right) pt, bottom gap \(bottom) pt (field \(field), disc \(disc))")
            #expect(right > 0 && bottom > 0, "the disc is inside the field")
        }
    }

    /// Multi-line: the button stays on the last line's bottom-right while the field grows and then
    /// scrolls, never covers the text, and the first character never rewraps the field.
    @Test func multiLineKeepsTheButtonPinnedWithNoLayoutShift() async throws {
        let h = try await makeHarness()
        defer { close(h) }
        let maybeCompose = h.view.controller.demo?.compose
        try #require(maybeCompose != nil)
        let compose = maybeCompose!
        let button = h.view.controller.host.sendButton
        let emptyClip = compose.textView.clip.frame
        await type(h, "a")
        let oneLine = button.frame
        let oneLineClip = compose.textView.clip.frame
        let oneLineField = compose.fieldRect
        #expect(oneLineClip.width == emptyClip.width, "the first character keeps the text width (no rewrap)")
        #expect(oneLineField.contains(CGPoint(x: oneLine.midX, y: oneLine.midY)))
        for i in 0..<30 {
            await type(h, "\nline \(i) of a long message that keeps going")
            let f = compose.fieldRect, b = button.frame, clip = compose.textView.clip.frame
            #expect(abs(b.maxY - oneLine.maxY) < 0.5 && abs(b.maxX - oneLine.maxX) < 0.5, "pinned bottom-right at \(i): \(b) vs \(oneLine)")
            #expect(b.maxY <= f.maxY + 0.5 && b.maxX <= f.maxX + 0.5, "inside the field at \(i)")
            #expect(clip.maxX <= b.minX + 0.5, "the text never runs under the button at \(i): clip \(clip) button \(b)")
        }
        let fieldHeight = compose.fieldRect.height
        #expect(fieldHeight <= ComposeView.maxHeight + 1, "the field stops at its max height, then scrolls")
        let finalShown = Self.shown(h)
        #expect(finalShown)
    }

    /// p03-rendering-074 (Chromium's one NSView per widget, components/remote_cocoa/app_shim/
    /// bridged_content_view.mm): the send button, the voice controls and "Listening…" are layers of
    /// one view that covers the pane, so no NSView of the compose bar's own lies in the field. On the
    /// base there were 9: the send button, the voice controls with their waveform, finish and mic
    /// buttons and those buttons' glyphs, and "Listening…" with its label.
    @Test func theComposeBarsControlsAreNoViewsInTheField() async throws {
        let h = try await makeHarness()
        defer { close(h) }
        let maybeCompose = h.view.controller.demo?.compose
        try #require(maybeCompose != nil)
        let compose = maybeCompose!
        let host = h.view.controller.host
        let skipping: [NSView] = [host.fieldChrome, compose.textView.clip, host.scrollView, host.paneHeader]
        for text in ["", "typed"] {
            if !text.isEmpty { await type(h, text) }
            let inField = Self.viewsInField(host, field: compose.fieldRect, skipping: skipping)
            let chromeViews = Self.viewCount(host.composeChrome)
            #expect(inField.isEmpty, "draft '\(text)': NSViews in the field (the base had 9): \(inField)")
            #expect(chromeViews == 1, "draft '\(text)': the controls view has \(chromeViews - 1) subviews")
        }
    }

    /// A plain key (the field keeps its height, the button its state) does only the text's work: no
    /// layout of the pane, no view outside the field asks for a layout or a display, the controls
    /// do not move, show or hide, and their layer tree commits no change. Every view is clean before
    /// each key, so whatever is dirty after it is the key's.
    @Test func aKeyDirtiesNoComposerViewOutsideTheField() async throws {
        let h = try await makeHarness()
        defer { close(h) }
        let host = h.view.controller.host
        let chrome = host.composeChrome
        await type(h, "first")  // the button shows (one change); each key after it is a plain key
        var dirty: [String] = []
        for c in " more keys on the same line" {
            host.layoutSubtreeIfNeeded()  // sync-layout: the key's own layout is measured from a clean tree
            Self.markClean(host, outside: h.field)
            let layouts = host.layoutPasses, changes = chrome.controlsChanges
            let layers = Self.layerStates(chrome.layer)
            h.field.insertText(String(c), replacementRange: h.field.selectedRange())
            for _ in 0..<8 { await Task.yield() }
            if host.layoutPasses != layouts { dirty.append("'\(c)': the pane laid out \(host.layoutPasses - layouts) times") }
            if chrome.controlsChanges != changes { dirty.append("'\(c)': the controls changed \(chrome.controlsChanges - changes) times") }
            let after = Self.layerStates(chrome.layer)
            if after.count != layers.count { dirty.append("'\(c)': \(layers.count) layers -> \(after.count)") }
            dirty += zip(layers, after).filter { pair in pair.0 != pair.1 }.map { pair in "'\(c)': layer \(pair.0) -> \(pair.1)" }
            dirty += Self.dirtyViews(host, outside: h.field).map { "'\(c)': \($0)" }
        }
        let report = dirty.joined(separator: "\n")
        #expect(report.isEmpty, "a plain key did work outside the field:\n\(report)")
    }

    /// VoiceOver's mouse tracking, Voice Control and Accessibility Inspector find the send button
    /// under the pointer through the window's hit test, and Full Keyboard Access's focus on it is the
    /// button's element, not the controls view's ancestor (Chromium: BridgedContentView's
    /// accessibilityHitTest and accessibilityFocusedUIElement).
    @Test func theWindowsHitTestAndFocusReachTheSendButtonsElement() async throws {
        let h = try await makeHarness()
        defer { close(h) }
        let host = h.view.controller.host
        let chrome = host.composeChrome
        chrome.fullKeyboardAccess = { true }
        await type(h, "hi")
        let f = host.sendButton.frame
        let screen = h.window.convertPoint(toScreen: chrome.convert(CGPoint(x: f.midX, y: f.midY), to: nil))
        let hit = (h.window.accessibilityHitTest(screen) as? NSAccessibilityElement)?.accessibilityIdentifier()
        #expect(hit == Self.identifier, "the window's hit test at the button's centre found \(hit ?? "no element")")
        let focused = h.window.makeFirstResponder(chrome)
        #expect(focused, "Full Keyboard Access: the send button takes the keyboard focus")
        let element = h.window.accessibilityFocusedUIElement as? NSAccessibilityElement
        let focusedID = element?.accessibilityIdentifier()
        let isFocused = element?.isAccessibilityFocused() == true
        let parentIsChrome = element?.accessibilityParent().map { $0 as AnyObject } === chrome
        #expect(focusedID == Self.identifier, "the focused element is \(focusedID ?? "no element")")
        #expect(isFocused, "the send button's element says it is focused")
        #expect(!parentIsChrome, "its parent is an element, not the ignored controls view")
    }

    /// The Full Keyboard Access ring shows only while its window is key, as AppKit's focus ring did:
    /// it goes when the window resigns key (Cmd-Tab, another window) and comes back when it is key.
    @Test func theFocusRingShowsOnlyInTheKeyWindow() async throws {
        let h = try await makeHarness()
        defer { close(h) }
        let chrome = h.view.controller.host.composeChrome
        chrome.fullKeyboardAccess = { true }
        await type(h, "hi")
        let focused = h.window.makeFirstResponder(chrome)
        try #require(focused)
        let offscreenRing = chrome.isFocusRingShown
        #expect(!offscreenRing, "the window is not key: no ring")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: h.window)
        let keyRing = chrome.isFocusRingShown
        #expect(keyRing, "the window became key: the ring shows")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: h.window)
        let resignedRing = chrome.isFocusRingShown
        #expect(!resignedRing, "the window resigned key: the ring goes")
    }

    /// Views under `root`, outside the `skipping` subtrees, whose frame lies in the field.
    private static func viewsInField(_ root: NSView, field: CGRect, skipping: [NSView]) -> [String] {
        var found: [String] = []
        var views = root.subviews
        while let v = views.popLast() {
            if skipping.contains(where: { $0 === v }) { continue }
            let frame = v.convert(v.bounds, to: root)
            if !frame.isEmpty, field.insetBy(dx: -1, dy: -1).contains(frame) { found.append("\(type(of: v)) \(frame)") }
            views += v.subviews
        }
        return found
    }

    private static func viewCount(_ root: NSView) -> Int {
        1 + root.subviews.reduce(0) { $0 + viewCount($1) }
    }

    /// The field's own views (its text view, scroll view and clip) and its caret (it moves with the
    /// text: it is part of the text's line).
    private static func isFieldView(_ v: NSView, _ field: NSView) -> Bool {
        let fieldViews: [NSView] = [field.enclosingScrollView?.superview, field.enclosingScrollView, field].compactMap { $0 }
        return v is CaretView || fieldViews.contains { v === $0 || v.isDescendant(of: $0) }
    }

    /// Marks every view under `root` outside the field displayed (an offscreen window keeps a view
    /// dirty), so a view that asks for a display afterwards asked for it then.
    private static func markClean(_ root: NSView, outside field: NSView) {
        var views: [NSView] = [root]
        while let v = views.popLast() {
            if isFieldView(v, field) { continue }
            v.needsDisplay = false
            views += v.subviews
        }
    }

    /// The views under `root`, outside the field, that ask for a layout or a display now.
    private static func dirtyViews(_ root: NSView, outside field: NSView) -> [String] {
        var found: [String] = []
        var views: [NSView] = [root]
        while let v = views.popLast() {
            if isFieldView(v, field) { continue }
            let id = "\(type(of: v)) \(ObjectIdentifier(v).hashValue)"
            if v.needsLayout { found.append("\(id) needs layout") }
            if v.needsDisplay { found.append("\(id) needs display") }
            views += v.subviews
        }
        return found
    }

    /// What a commit of `root`'s layer tree would show: each layer's geometry, visibility, colours,
    /// contents, mask and path (by identity: a new image or path is a change even when it looks the same).
    private static func layerStates(_ root: CALayer) -> [String] {
        var out: [String] = []
        var stack: [(layer: CALayer, path: String)] = [(root, "root")]
        while let item = stack.popLast() {
            let l = item.layer, t = l.transform
            let contents = l.contents.map { "\(ObjectIdentifier($0 as AnyObject))" } ?? "nil"
            let mask = l.mask.map { "\(ObjectIdentifier($0))" } ?? "nil"
            var line = "\(item.path) frame \(l.frame) hidden \(l.isHidden) opacity \(l.opacity) scale \(t.m11) \(t.m22)"
            line += " background \(String(describing: l.backgroundColor)) contents \(contents) mask \(mask)"
            if let s = l as? CAShapeLayer {
                let path = s.path.map { "\(ObjectIdentifier($0))" } ?? "nil"
                line += " path \(path) stroke \(String(describing: s.strokeColor))"
            }
            out.append(line)
            for (i, sub) in (l.sublayers ?? []).enumerated() { stack.append((sub, "\(item.path).\(i)")) }
        }
        return out
    }
}
