import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// POLISH audit, batch 3 (cx-2grmt): a page's menu shown past its window's edge (a `<select>`,
/// WebPopupHost) drew the system window shadow and appeared and left in one frame. It casts the
/// one popup shadow (`PopupStyle`, like the page's own menus) and opens and closes like every
/// native popup (`openPopup` / `closePopup`).
@MainActor @Suite(.serialized, .closesItsWindows) struct PagePopupMotionTests {
    /// Popup motion is observable only on an awake display with animations enabled. The tests pin
    /// Reduce Motion off around the operation, so the system Reduce Motion setting does not gate
    /// this predicate.
    @Test(.enabled("needs an awake display and animations on, or every popup snaps anyway") { await GUIAnimationTestSupport.animatesHere() })
    func aPageMenuCastsThePopupShadowAndOpensAndClosesWithMotion() async throws {
        let (window, page) = try Self.page()
        defer { window.closeAfterTest() }
        let host = WebPopupHost(webView: page, zoom: { 1 }, send: { _ in })
        // Opening is synchronous; the close may animate. The override is process-wide.
        let (reply, panel, opened) = try { () throws -> ([String: Any], WebPopupPanel, Bool) in
            Motion.reduceMotionOverride = false
            defer { Motion.reduceMotionOverride = nil }
            let reply = host.show(try Self.menu(["a", "b"]))
            let panel = try #require(NSApp.windows.compactMap { $0 as? WebPopupPanel }.first { $0.parent === window })
            return (reply, panel, panel.contentView?.layer?.animationKeys()?.isEmpty ?? true)
        }()
        #expect(!panel.hasShadow, "the system window shadow")
        let card = try #require(panel.contentView as? PopupHostView, "no popup shadow").card
        // The reply and `shownFrame` name the menu's card, not its shadow band.
        let frame = try #require(reply["frame"] as? [CGFloat])
        #expect(host.shownFrame == CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]))
        #expect(host.shownFrame?.size == card.frame.size)
        #expect(opened, "the menu animated in")

        host.hide()
        #expect(panel.isVisible, "closed in one frame")
        #expect(await GUIAnimationTestSupport.settle { !panel.isVisible }, "the close never ended")
    }

    static func menu(_ ids: [String], instant: Bool? = nil) throws -> WebPopupHost.Model {
        var params: [String: Any] = [
            "items": ids.map { ["id": $0, "label": $0] },
            "anchor": ["left": 40, "top": 40, "right": 200, "bottom": 64], "width": 160,
        ]
        if let instant { params["instant"] = instant }
        return try #require(WebPopupHost.Model(params))
    }

    /// Leo 2026-10-22, no entry animations on the New Tab: its menus ask for none (`instant: true`).
    @Test func theInstantFlagIsReadFromThePageRequest() throws {
        #expect(try Self.menu(["a"], instant: true).instant)
        #expect(try !Self.menu(["a"]).instant)
        #expect(try !Self.menu(["a"], instant: false).instant)
    }

    /// No entrance asked: the card shows whole in one frame, and its close still fades.
    @Test(.enabled("needs an awake display and animations on, or every popup snaps anyway") { await GUIAnimationTestSupport.animatesHere() })
    func anInstantPageMenuOpensInOneFrameAndStillFadesOut() async throws {
        let (window, page) = try Self.page()
        defer { window.closeAfterTest() }
        let host = WebPopupHost(webView: page, zoom: { 1 }, send: { _ in })
        let (panel, opening, opacity) = try { () throws -> (WebPopupPanel, [String], Float?) in
            Motion.reduceMotionOverride = false
            defer { Motion.reduceMotionOverride = nil }
            host.show(try Self.menu(["a", "b"], instant: true))
            let panel = try #require(NSApp.windows.compactMap { $0 as? WebPopupPanel }.first { $0.parent === window })
            let layer = panel.contentView?.layer
            return (panel, ["opacity", "sublayerTransform"].filter { layer?.animation(forKey: $0) != nil }, layer?.opacity)
        }()
        #expect(opening == [], "the menu animated in")
        #expect(opacity == 1)
        #expect(panel.alphaValue == 1)

        Motion.reduceMotionOverride = false
        host.hide()
        let closing = panel.contentView?.layer?.animation(forKey: "opacity") != nil
        Motion.reduceMotionOverride = nil
        #expect(closing, "the close lost its fade")
        #expect(await GUIAnimationTestSupport.settle { !panel.isVisible }, "the close never ended")
    }

    /// Review of #27136: menus open in one frame, but a page tooltip that does not ask for
    /// `instant` (every tooltip outside New Tab, `popupHost.ts`) keeps its fade and grow in.
    @Test(.enabled("needs an awake display and animations on, or every popup snaps anyway") { await GUIAnimationTestSupport.animatesHere() })
    func aPageTooltipKeepsItsEntranceUnlessItAsksForNone() async throws {
        for instant in [false, true] {
            let (window, page) = try Self.page()
            defer { window.orderOut(nil) }
            let host = WebPopupHost(webView: page, zoom: { 1 }, send: { _ in })
            var params: [String: Any] = [
                "items": [["id": "tip", "label": "A tooltip"]], "kind": "tooltip",
                "anchor": ["left": 40, "top": 40, "right": 200, "bottom": 64], "width": 160,
            ]
            if instant { params["instant"] = true }
            let model = try #require(WebPopupHost.Model(params))
            let opening = try { () throws -> [String] in
                Motion.reduceMotionOverride = false
                defer { Motion.reduceMotionOverride = nil }
                host.show(model)
                let panel = try #require(NSApp.windows.compactMap { $0 as? WebPopupPanel }.first { $0.parent === window })
                let layer = panel.contentView?.layer
                return ["opacity", "sublayerTransform"].filter { layer?.animation(forKey: $0) != nil }
            }()
            if instant {
                #expect(opening == [], "an instant tooltip animated in")
            } else {
                #expect(opening == ["opacity", "sublayerTransform"], "the tooltip lost its entrance")
            }
            host.hide()
            #expect(await GUIAnimationTestSupport.settle { host.shownFrame == nil })
        }
    }

    /// Native menus and popovers use the host's default: no entrance motion.
    @Test(.enabled("needs an awake display and animations on, or every popup snaps anyway") { await GUIAnimationTestSupport.animatesHere() })
    func aNativePopupDefaultsToAnInstantOpenAndFadesOnClose() async throws {
        let (window, _) = try Self.page()
        defer { window.closeAfterTest() }
        let panel = NativePopupPanel(identifier: "cmux.tests.instant-popup")
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 80))
        content.wantsLayer = true
        panel.contentView = content
        let host = NativePopupHost(panel: panel)
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }

        _ = try #require(host.show(size: content.frame.size,
                                   anchor: CGRect(x: 300, y: 580, width: 24, height: 24),
                                   in: window))
        #expect(content.layer?.animation(forKey: "opacity") == nil, "the popup fades in")
        #expect(content.layer?.animation(forKey: "sublayerTransform") == nil, "the popup grows in")
        #expect(content.layer?.opacity == 1)

        host.hide()
        #expect(content.layer?.animation(forKey: "opacity") != nil, "the popup lost its close fade")
        #expect(await GUIAnimationTestSupport.settle { !panel.isVisible }, "the close never ended")
    }

    /// A submenu is a child panel, but still owns keyboard focus while it is open. Hiding it
    /// returns the keys to its parent so Escape and typeahead remain scoped to the active menu.
    @Test(.enabled("needs an awake display") { !NSScreen.screens.isEmpty })
    func aChildPopupTakesKeyboardAndReturnsItToItsParent() async throws {
        let (window, page) = try Self.page()
        defer { window.orderOut(nil) }
        var events: [[String: Any]] = []
        let host = DeclarativePopupHost(webView: page, zoom: { 1 }, send: { events.append($0) }, isAppActive: { true })
        defer { host.hide() }
        var model = NativePopupModel(schemaVersion: 1, id: "submenu-focus", revision: 1,
                                     anchor: NativePopupAnchor(left: 20, top: 30, right: 120, bottom: 60),
                                     side: .bottom, align: .start, width: 240,
                                     rows: [NativePopupRow(id: "more", kind: .submenu, label: "More",
                                                           children: [NativePopupRow(id: "pick", kind: .action, label: "Pick"),
                                                                      NativePopupRow(id: "second", kind: .action, label: "Second", keepOpen: true)])],
                                     highlighted: "more")
        #expect(host.show(model)["shown"] as? Bool == true)
        let parentPanel = try #require(window.childWindows?.compactMap { $0 as? NativePopupPanel }.first)
        #expect(await GUIAnimationTestSupport.settle { parentPanel.isKeyWindow })
        let parentContent = try #require(parentPanel.firstResponder as? NativePopupContent)
        let rightArrow = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                     timestamp: 0, windowNumber: parentPanel.windowNumber,
                                                     context: nil, characters: "", charactersIgnoringModifiers: "",
                                                     isARepeat: false, keyCode: 124))
        parentContent.keyDown(with: rightArrow)
        let childPanel = try #require(parentPanel.childWindows?.compactMap { $0 as? NativePopupPanel }.first)
        #expect(await GUIAnimationTestSupport.settle { childPanel.isKeyWindow }, "the submenu did not take keyboard focus")
        #expect(host.activeID == model.id && host.shownFrame != nil, "opening the submenu dismissed its parent")
        let parentCard = try #require(host.shownFrame)
        let childCard = PopupStyle.standard.cardFrame(inWindow: childPanel.frame)
        #expect(childCard.minX >= parentCard.maxX, "root alignment pulled the submenu over its parent")
        let childContent = try #require(childPanel.firstResponder as? NativePopupContent)
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: childPanel.windowNumber, context: nil, characters: "",
                                               charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
        childContent.keyDown(with: down)
        events.removeAll()
        model.revision += 1
        model.width += 40
        model.rows.append(NativePopupRow(id: "extra", kind: .action, label: "Extra"))
        host.update(model)
        // Drain the main-actor notification work queued by resizing the ancestor panel.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(host.activeID == model.id && host.shownFrame != nil)
        #expect(childPanel.isVisible && childPanel.isKeyWindow, "ancestor layout dismissed its submenu")
        let resizedParentCard = try #require(host.shownFrame)
        #expect(PopupStyle.standard.cardFrame(inWindow: childPanel.frame).minX >= resizedParentCard.maxX,
                "resizing the leading-aligned parent left the child at its old anchor")
        #expect(events.isEmpty)
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: childPanel.windowNumber, context: nil, characters: "",
                                                charactersIgnoringModifiers: "", isARepeat: false, keyCode: 36))
        childContent.keyDown(with: enter)
        #expect(events.count == 1 && events.first?["id"] as? String == "second", "root highlight replaced the child's selection")
        events.removeAll()
        childContent.dismiss()
        #expect(await GUIAnimationTestSupport.settle { parentPanel.isKeyWindow }, "hiding the submenu did not restore its parent")
        #expect(parentPanel.firstResponder === parentContent)
        #expect(events.isEmpty, "closing a child must not dismiss the React root")

        parentContent.keyDown(with: rightArrow)
        let disabledChild = try #require(parentPanel.childWindows?.compactMap { $0 as? NativePopupPanel }.first { $0.isKeyWindow })
        let disabledContent = try #require(disabledChild.firstResponder as? NativePopupContent)
        let oldRow = model.rows[0]
        model.revision += 1
        model.rows[0].disabled = true
        host.update(model)
        #expect(await GUIAnimationTestSupport.settle { !disabledChild.isVisible })
        disabledContent.emit(.pick, "pick", nil)
        parentContent.openSubmenu(oldRow, parentContent)
        #expect(events.isEmpty, "a disabled ancestor or stale row must not authorize a child action")
        #expect(host.activeID == model.id)
        #expect(await GUIAnimationTestSupport.settle { parentPanel.childWindows?.contains { $0.isVisible } != true })
        host.hide()
        #expect(await GUIAnimationTestSupport.settle { !parentPanel.isVisible && !childPanel.isVisible })
    }

    @Test(.enabled("needs an awake display") { !NSScreen.screens.isEmpty })
    func numberedActionsRespectKeepOpenAndDisabledRows() throws {
        let (window, page) = try Self.page()
        defer { window.orderOut(nil) }
        var events: [[String: Any]] = []
        let host = DeclarativePopupHost(webView: page, zoom: { 1 }, send: { events.append($0) }, isAppActive: { true })
        defer { host.hide() }
        var model = NativePopupModel(schemaVersion: 1, id: "numbered", revision: 1,
                                     anchor: NativePopupAnchor(left: 20, top: 30, right: 120, bottom: 60),
                                     side: .bottom, align: .start, width: 240, rows: [])
        model.rows = (1...9).map { number in
            NativePopupRow(id: "pick-\(number)", kind: .action, label: "Pick \(number)", shortcut: "\(number)", keepOpen: true)
        }
        #expect(host.show(model)["shown"] as? Bool == true)
        let panel = try #require(window.childWindows?.compactMap { $0 as? NativePopupPanel }.first)
        let content = try #require(panel.firstResponder as? NativePopupContent)
        func key(_ number: Int) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: panel.windowNumber, context: nil, characters: "\(number)",
                                                     charactersIgnoringModifiers: "\(number)", isARepeat: false, keyCode: 18))
            content.keyDown(with: event)
        }
        for number in 1...9 {
            try key(number)
            #expect(events.count == number)
            #expect(events.last?["id"] as? String == "pick-\(number)")
            #expect(host.activeID == model.id)
        }
        model.revision += 1
        model.rows[0].disabled = true
        host.update(model)
        try key(1)
        #expect(events.count == 9)
        model.revision += 1
        model.rows[1].keepOpen = false
        host.update(model)
        try key(2)
        #expect(events.count == 11)
        #expect(events.filter { $0["type"] as? String == "pick" }.count == 10)
        #expect(events.last?["type"] as? String == "dismiss" && events.last?["popupId"] as? String == model.id)
        #expect(host.activeID == nil)
    }

    @Test(.enabled("needs an awake display") { !NSScreen.screens.isEmpty }, arguments: [NativePopupAutoHighlight.none, .first])
    func reopeningSearchStartsWithoutPriorSelectionOrTyping(policy: NativePopupAutoHighlight) throws {
        let (window, page) = try Self.page()
        defer { window.orderOut(nil) }
        var events: [[String: Any]] = []
        let host = DeclarativePopupHost(webView: page, zoom: { 1 }, send: { events.append($0) }, isAppActive: { true })
        defer { host.hide() }
        var model = NativePopupModel(schemaVersion: 1, id: "same-search", revision: 1,
                                     anchor: NativePopupAnchor(left: 20, top: 30, right: 120, bottom: 60),
                                     side: .bottom, align: .start, width: 240,
                                     rows: [NativePopupRow(id: "first", kind: .action, label: "First")],
                                     search: NativePopupField(id: "query", value: "", placeholder: "Search", submitOnReturn: true, autoHighlight: policy))
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func controls() throws -> (NativePopupContent, NSSearchField) {
            let panel = try #require(window.childWindows?.compactMap { $0 as? NativePopupPanel }.first)
            let root = try #require(panel.contentView)
            let content = try #require(descendants(root).compactMap { $0 as? NativePopupContent }.first)
            return (content, try #require(content.subviews.compactMap { $0 as? NSSearchField }.first))
        }
        #expect(host.show(model)["shown"] as? Bool == true)
        let (content, search) = try controls()
        search.stringValue = "typed"
        content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        model.revision += 1
        model.search?.value = "typed"
        host.update(model)
        if policy == .none { _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))) }
        _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(events.last?["type"] as? String == "submit")
        #expect(events.last?["id"] as? String == "first")
        host.hide()
        model.revision += 1
        #expect(host.show(model)["shown"] as? Bool == true)
        let (reopened, field) = try controls()
        _ = reopened.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(events.last?["type"] as? String == "submit")
        #expect(events.last?["value"] as? String == "typed")
        #expect(events.last?["id"] == nil, "a reopened popup inherited its prior selection")
        #expect(events.last?["reason"] as? String == "none")
    }

    @Test(.enabled("needs an awake display") { !NSScreen.screens.isEmpty })
    func aTrailingRootSubmenuFlipsAtTheScreenEdgeOnUpdate() throws {
        let (window, page) = try Self.page()
        defer { window.orderOut(nil) }
        let screen = try #require(window.screen).visibleFrame
        let host = DeclarativePopupHost(webView: page, zoom: { 1 }, send: { _ in }, isAppActive: { true })
        defer { host.hide() }
        var model = NativePopupModel(schemaVersion: 1, id: "submenu-geometry", revision: 1,
                                     anchor: NativePopupAnchor(left: 20, top: 30, right: 120, bottom: 60),
                                     side: .bottom, align: .end, width: 240,
                                     rows: [NativePopupRow(id: "more", kind: .submenu, label: "More",
                                                           children: [NativePopupRow(id: "pick", kind: .action, label: "Pick")])])
        #expect(host.show(model)["shown"] as? Bool == true)
        let panel = try #require(window.childWindows?.compactMap { $0 as? NativePopupPanel }.first)
        let content = try #require(panel.firstResponder as? NativePopupContent)
        let row = try #require(content.rowView(id: "more"))
        content.openSubmenu(model.rows[0], row)
        let child = try #require(panel.childWindows?.compactMap { $0 as? NativePopupPanel }.first)
        let initial = try #require(host.shownFrame)
        #expect(PopupStyle.standard.cardFrame(inWindow: child.frame).minX >= initial.maxX)
        let point = page.convert(window.convertPoint(fromScreen: CGPoint(x: screen.maxX - 8, y: screen.midY)), from: nil)
        model.revision += 1
        model.anchor = NativePopupAnchor(left: point.x - 100, top: page.bounds.height - point.y,
                                         right: point.x, bottom: page.bounds.height - point.y + 30)
        host.update(model)
        let moved = try #require(host.shownFrame)
        let childFrame = PopupStyle.standard.cardFrame(inWindow: child.frame)
        #expect(childFrame.maxX <= moved.minX, "the child must flip left beside the updated parent")
        #expect(screen.contains(childFrame))
    }

    /// A window on screen with a page view, and the page menu panel of `host` once shown.
    static func page() throws -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 500, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView = page
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        return (window, page)
    }

    /// Review of #19944: the page posts an update for the menu it is still closing (a highlight
    /// as Base UI closes it) after the menu went away here. It must not open again.
    @Test(.enabled("needs an awake display and animations on, or every popup snaps anyway") { await GUIAnimationTestSupport.animatesHere() })
    func anUpdateDuringTheCloseDoesNotReopenTheMenu() async throws {
        let (window, page) = try Self.page()
        defer { window.closeAfterTest() }
        let host = WebPopupHost(webView: page, zoom: { 1 }, send: { _ in })
        host.show(try Self.menu(["a", "b"]))
        let panel = try #require(NSApp.windows.compactMap { $0 as? WebPopupPanel }.first { $0.parent === window })
        host.hide()
        host.update(try Self.menu(["a", "b", "c"]))
        #expect(await GUIAnimationTestSupport.settle { !panel.isVisible }, "the closed menu opened again")
        #expect(host.shownFrame == nil)
    }

    /// Review of #19944: the page's view goes (its tab closed) while its menu fades out. The menu
    /// still leaves its window.
    @Test(.enabled("needs an awake display and animations on, or every popup snaps anyway") { await GUIAnimationTestSupport.animatesHere() })
    func aMenuWhoseHostGoesMidFadeStillLeaves() async throws {
        let (window, page) = try Self.page()
        defer { window.closeAfterTest() }
        var host: WebPopupHost? = WebPopupHost(webView: page, zoom: { 1 }, send: { _ in })
        weak var gone = host
        host?.show(try Self.menu(["a", "b"]))
        let panel = try #require(NSApp.windows.compactMap { $0 as? WebPopupPanel }.first { $0.parent === window })
        host?.hide()
        host = nil
        #expect(gone == nil)
        #expect(await GUIAnimationTestSupport.settle { !panel.isVisible }, "a dead host's menu stayed on its window")
        #expect(panel.parent == nil)
    }
}
