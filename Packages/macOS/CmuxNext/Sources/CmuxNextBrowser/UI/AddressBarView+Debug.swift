public import AppKit

/// What automation reads about the omnibar (`debug.omnibar`): the state
/// machine and the field editor side by side, so a test sees both the model
/// and what AppKit shows.
public struct OmnibarDebugSnapshot: Sendable, Equatable {
    public var phase: String
    public var hasFocus: Bool
    /// The focused field shows the steady-state (elided) URL.
    public var elided: Bool
    /// What the model says the field shows, and its selection (UTF-16).
    public var text: String
    public var selection: NSRange?
    /// What the field (or its field editor) actually holds.
    public var fieldText: String
    public var fieldSelection: NSRange?
    public var fieldEditorActive: Bool
    public var rows: [String]
    public var highlighted: Int?
    /// What Copy would put on the pasteboard now (nothing is written).
    public var copyText: String?
    /// Omnibox preloading: whether a tab preloads for this omnibar, the last request's text and
    /// default match, what the tab answered (prerender, preconnect, none, unavailable) and the last
    /// end sent (the opened URL, and whether the predictor learned from it).
    public var preloadBound = false
    public var preloadText: String?
    public var preloadDefault: String?
    public var preloadAction: String?
    public var preloadEndOpened: String?
    public var preloadEndLearn: Bool?

    /// The preload fields as `debug.omnibar`'s `preload` object (absent values left out).
    public var preloadReport: [String: String] {
        var report = ["bound": preloadBound ? "true" : "false"]
        report["text"] = preloadText
        report["default"] = preloadDefault
        report["action"] = preloadAction
        report["end_opened"] = preloadEndOpened
        report["end_learn"] = preloadEndLearn.map { $0 ? "true" : "false" }
        return report
    }
}

/// A synthesized mouse gesture over the omnibar text (`debug.mouse`).
public struct OmnibarDebugMouse: Sendable {
    public enum Button: Sendable { case left, right }
    /// Character index the press lands on (the leading edge of that
    /// character; the text length means after the last one).
    public var character: Int
    /// Drag to this character before the release.
    public var dragTo: Int?
    public var clickCount: Int
    public var button: Button

    public init(character: Int, dragTo: Int? = nil, clickCount: Int = 1, button: Button = .left) {
        self.character = character
        self.dragTo = dragTo
        self.clickCount = clickCount
        self.button = button
    }
}

extension AddressBarView {
    public var debugSnapshot: OmnibarDebugSnapshot {
        let state = controller.state
        let presentation = OmnibarPresentation(state)
        let editor = field.currentEditor() as? NSTextView
        let phase = switch state.phase {
        case .idle: "idle"
        case .focused: "focused"
        case .editing: "editing"
        case .committing: "committing"
        }
        var snapshot = OmnibarDebugSnapshot(
            phase: phase,
            hasFocus: state.hasFocus,
            elided: state.elided,
            text: presentation.text,
            selection: presentation.selection,
            fieldText: editor?.string ?? field.stringValue,
            fieldSelection: editor?.selectedRange(),
            fieldEditorActive: editor != nil,
            rows: presentation.rows.map(\.title),
            highlighted: presentation.highlighted,
            copyText: OmnibarReducer.copyContent(of: state, resolver: suggestionEngine.resolver)?.text
        )
        snapshot.preloadBound = controller.preloader != nil
        snapshot.preloadText = controller.lastPreload?.text
        snapshot.preloadDefault = controller.lastPreload?.matches.first?.url.absoluteString
        snapshot.preloadAction = controller.lastPreloadAction.map { action in
            switch action {
            case .prerender: "prerender"
            case .preconnect: "preconnect"
            case .none: "none"
            case .unavailable: "unavailable"
            }
        }
        snapshot.preloadEndOpened = controller.lastPreloadEnd?.opened?.absoluteString
        snapshot.preloadEndLearn = controller.lastPreloadEnd?.learn
        return snapshot
    }

    /// `debug.omnibar`'s `preload` object; with `pageTiming`, also `page_timing`: the bound tab's
    /// navigation timing as JSON (`url`, `origin`, `fcp`, `activation`; bench `omnibar`). It is read
    /// with no gesture and no agent mark: an agent's `browser.page.eval` marks the tab agent-driven,
    /// and such a tab never preloads. Each call starts a read and reports the one before.
    public func debugPreloadReport(pageTiming: Bool) -> [String: String] {
        var report = debugSnapshot.preloadReport
        guard pageTiming, let tab = controller.preloader as? any BrowserTab else { return report }
        report["page_timing"] = controller.debugPageTiming
        guard !controller.debugPageTimingReading else { return report }
        controller.debugPageTimingReading = true
        Task { [weak controller] in  // inherits the view's main actor
            let value = try? await tab.evaluate(Self.pageTimingScript, world: .isolated, gesture: .cmux)
            if case .string(let json)? = value { controller?.debugPageTiming = json }
            controller?.debugPageTimingReading = false
        }
        return report
    }

    /// The shown document's URL, time origin, first contentful paint and prerender activation start (ms).
    static let pageTimingScript = """
        (() => {
          const n = performance.getEntriesByType('navigation')[0];
          const f = performance.getEntriesByName('first-contentful-paint')[0];
          return JSON.stringify({url: location.href, origin: performance.timeOrigin,
                                 fcp: f ? f.startTime : null, activation: n ? (n.activationStart || 0) : 0});
        })()
        """

    /// Dispatches a press (and drag) and release over the omnibar text the
    /// way `NSWindow.sendEvent` does for a key window: the hit view becomes
    /// first responder, then gets the press, while the release and drags
    /// wait in the event queue for AppKit's own tracking loop. Never
    /// activates the app or makes the window key. The context menu of a
    /// right-click is skipped (it would run a modal loop). Returns an error.
    public func debugMouse(_ gesture: OmnibarDebugMouse) -> String? {
        guard let window, let contentView = window.contentView else { return "no window" }
        let press = point(forCharacter: gesture.character)
        let now = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ at: NSPoint, _ offset: Double) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: now + offset,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: gesture.clickCount, pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1)
        }
        let right = gesture.button == .right
        guard let down = event(right ? .rightMouseDown : .leftMouseDown, press, 0) else { return "bad event" }
        var queued: [NSEvent] = []
        if let target = gesture.dragTo, !right {
            let end = point(forCharacter: target)
            for step in 1...4 {
                let t = CGFloat(step) / 4
                let at = NSPoint(x: press.x + (end.x - press.x) * t, y: press.y)
                if let drag = event(.leftMouseDragged, at, 0.01 * Double(step)) { queued.append(drag) }
            }
            if let up = event(.leftMouseUp, end, 0.05) { queued.append(up) }
        } else if let up = event(right ? .rightMouseUp : .leftMouseUp, press, 0.02) {
            queued.append(up)
        }
        guard var hit = contentView.hitTest(contentView.superview?.convert(press, from: nil) ?? press) else { return "no view at the point" }
        guard hit.isDescendant(of: field) else { return "the omnibar text is covered" }
        // While editing, the field editor (inside the field's clip view) owns
        // every press over the text.
        if let editor = field.currentEditor() as? NSTextView { hit = editor }
        if right {
            let editor = (field.cell as? AddressFieldCell)?.editor
            editor?.suppressesContextMenu = true
            defer { editor?.suppressesContextMenu = false }
            pendingFocusSource = .mouse
            defer { pendingFocusSource = nil }
            hit.rightMouseDown(with: down)
            return nil
        }
        for queuedEvent in queued { NSApp.postEvent(queuedEvent, atStart: false) }
        if hit !== window.firstResponder, hit.acceptsFirstResponder {
            pendingFocusSource = .mouse
            window.makeFirstResponder(hit)
            pendingFocusSource = nil
        }
        hit.mouseDown(with: down)
        return nil
    }

    /// Window point on the text baseline's middle at `index`.
    private func point(forCharacter index: Int) -> NSPoint {
        if let editor = field.currentEditor() as? NSTextView, let layout = editor.layoutManager, let container = editor.textContainer {
            let length = (editor.string as NSString).length
            let clamped = min(max(index, 0), length)
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: min(clamped, max(length - 1, 0)), length: length == 0 ? 0 : 1), actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let x = (clamped == length ? rect.maxX : rect.minX) + editor.textContainerOrigin.x + 0.5
            return editor.convert(NSPoint(x: x, y: rect.midY + editor.textContainerOrigin.y), to: nil)
        }
        let text = field.attributedStringValue
        let clamped = min(max(index, 0), text.length)
        let prefix = text.attributedSubstring(from: NSRange(location: 0, length: clamped)).size().width
        let origin = field.cell?.titleRect(forBounds: field.bounds).minX ?? 2
        return field.convert(NSPoint(x: origin + prefix + 2 + 0.5, y: field.bounds.midY), to: nil)
    }
}

extension AddressBarView {
    /// The field's frame in window coordinates (`debug.omnibar_bench` clicks its middle).
    public var debugFieldFrameInWindow: NSRect { field.convert(field.bounds, to: nil) }

    /// The bar shows editing now: the field editor is attached and the pill
    /// wears the editing look (ring, or the card top), with no fade left to run.
    public var debugShowsEditing: Bool {
        controller.state.hasFocus && field.isFieldEditorActive && pill.state != .idle && !pill.debugIsFading
    }

    /// How the field editor draws its selection (`debug.omnibar` `editor`):
    /// its text system, whether the window is key and the editor first
    /// responder (AppKit draws the unemphasized color otherwise), and the
    /// selection background resolved in the editor's appearance. Reads
    /// `textLayoutManager` only: touching `layoutManager` would switch a
    /// TextKit 2 editor to TextKit 1 for good.
    public var debugEditorInfo: [String: String] {
        guard let editor = field.currentEditor() as? NSTextView else { return [:] }
        var info: [String: String] = [
            "text_kit": editor.textLayoutManager == nil ? "1" : "2",
            "window_key": String(window?.isKeyWindow ?? false),
            "first_responder": String(window?.firstResponder === editor),
            "draws_background": String(editor.drawsBackground),
            "layer_backed": String(editor.layer != nil),
            "editor_class": String(describing: type(of: editor)),
            // The fonts the omnibar draws with: the style's, the field's, the editor's typed text and its typing font.
            "font_style": String(format: "%.2f", OmnibarStyle.font.pointSize),
            "font_field": String(format: "%.2f", field.font?.pointSize ?? 0),
            "font_typed": editor.textStorage.flatMap { $0.length > 0 ? $0.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil }
                .map { String(format: "%.2f", $0.pointSize) } ?? "-",
            "font_typing": (editor.typingAttributes[.font] as? NSFont).map { String(format: "%.2f", $0.pointSize) } ?? "-",
        ]
        // The field in global top-left screen points (screencapture -R).
        if let window, let screen = window.screen ?? NSScreen.screens.first {
            let rect = window.convertToScreen(field.convert(field.bounds, to: nil))
            let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
            info["screen_rect"] = String(format: "%.0f,%.0f,%.0f,%.0f", rect.minX, top - rect.maxY, rect.width, rect.height)
        }
        if let color = editor.selectedTextAttributes[.backgroundColor] as? NSColor {
            var resolved: NSColor?
            editor.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
            if let rgb = resolved {
                info["selection_bg"] = String(format: "%.3f %.3f %.3f %.3f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
            }
        } else {
            info["selection_bg"] = "none"
        }
        return info
    }

    /// The field editor holds its whole text selected (Chrome's focusing click).
    public var debugAllSelected: Bool {
        guard let editor = field.currentEditor() as? NSTextView else { return false }
        let length = (editor.string as NSString).length
        return length > 0 && editor.selectedRange() == NSRange(location: 0, length: length)
    }
}

extension AddressBarView {
    /// The omnibar edits and holds its window's keyboard: the window's first responder is its field
    /// (editor), so a key typed now lands in it (benches: `debug.new_tab` `omnibar.focus_ms`).
    public var editsAsFirstResponder: Bool {
        guard isEditing, let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }
}
