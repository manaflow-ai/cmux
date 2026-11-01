import AppKit
@testable import CmuxNextDesign
import Testing

@MainActor @Suite(.serialized) struct NativePopupReplacementTests {
    @Test(.enabled("needs an awake display") { !NSScreen.screens.isEmpty })
    func replacementDiscardsOldCompositionWithAReusedSearchID() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView = page
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var events: [[String: Any]] = []
        let host = DeclarativePopupHost(webView: page, zoom: { 1 }, send: { events.append($0) }, isAppActive: { true })
        defer { host.hide() }
        var model = NativePopupModel(schemaVersion: 1, id: "old", revision: 1,
                                     anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                     side: .bottom, align: .start, width: 320,
                                     rows: [NativePopupRow(id: "old-row", kind: .action, label: "Old")],
                                     search: NativePopupField(id: "query", value: "old", placeholder: "Old search"))
        #expect(host.show(model)["shown"] as? Bool == true)
        let panel = try #require(window.childWindows?.compactMap { $0 as? NativePopupPanel }.first)
        let root = try #require(panel.contentView)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let content = try #require(descendants(root).compactMap { $0 as? NativePopupContent }.first)
        let old = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        let editor = try #require(old.currentEditor() as? NSTextView)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        model.id = "replacement"
        model.rows = [NativePopupRow(id: "new-row", kind: .action, label: "New")]
        model.search?.value = "new query"
        #expect(host.show(model)["shown"] as? Bool == true)
        let replacement = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        #expect(replacement !== old && replacement.stringValue == "new query")
        #expect(content.rowView(id: "old-row") == nil && content.rowView(id: "new-row") != nil)
        let nextEditor = try #require(replacement.currentEditor() as? NSTextView)
        #expect(!nextEditor.hasMarkedText())
        old.stringValue = "old composition commit"
        content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: old))
        #expect(replacement.stringValue == "new query")
        #expect(events.count == 1 && events.first?["type"] as? String == "dismiss")
        #expect(events.first?["popupId"] as? String == "old")
    }

    @Test(.enabled("needs an awake display") { !NSScreen.screens.isEmpty }, arguments: ["remove", "disable", "kind"])
    func retiredComposingFieldCannotWriteIntoAReusedIdentity(_ replacementKind: String) throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NativePopupContent()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var model = NativePopupModel(schemaVersion: 1, id: "same", revision: 1,
                                     anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                     side: .bottom, align: .start, width: 320, rows: [],
                                     search: NativePopupField(id: "query", value: "old", placeholder: "Search", editSequence: 0))
        content.update(model)
        content.focusInitial()
        let old = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        old.stringValue = "pending old identity"
        content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: old))
        let editor = try #require(old.currentEditor() as? NSTextView)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        model.revision = 2
        if replacementKind == "disable" { model.search?.disabled = true } else { model.search = nil }
        if replacementKind == "kind" {
            model.rows = [NativePopupRow(id: "query", kind: .textField, label: "Text", value: "replacement", editSequence: 0)]
        }
        content.update(model)
        model.revision = 3
        if replacementKind != "kind" {
            model.search = NativePopupField(id: "query", value: "replacement", placeholder: "Search", editSequence: 0)
        }
        content.update(model)
        var edits = 0
        content.emit = { _, _, _ in edits += 1 }
        editor.unmarkText()
        old.stringValue = "retired composition"
        content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: old))
        let replacement = try #require(replacementKind == "kind"
            ? content.rowView(id: "query") as? NSTextField
            : content.subviews.compactMap { $0 as? NSSearchField }.first)
        #expect(replacement !== old && replacement.stringValue == "replacement")
        #expect(edits == 0)
    }

    @Test(.enabled("needs an awake display") { !NSScreen.screens.isEmpty })
    func deferredCommitKeepsItsOriginatingRevision() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView = page
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var events: [[String: Any]] = []
        let host = DeclarativePopupHost(webView: page, zoom: { 1 }, send: { events.append($0) }, isAppActive: { true })
        defer { host.hide() }
        var model = NativePopupModel(schemaVersion: 1, id: "same", revision: 1,
                                     anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                     side: .bottom, align: .start, width: 320, rows: [],
                                     search: NativePopupField(id: "query", value: "", placeholder: "Search", editSequence: 0))
        #expect(host.show(model)["shown"] as? Bool == true)
        let panel = try #require(window.childWindows?.compactMap { $0 as? NativePopupPanel }.first)
        let root = try #require(panel.contentView)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let content = try #require(descendants(root).compactMap { $0 as? NativePopupContent }.first)
        let field = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        model.revision = 2; model.title = "Updated"
        host.update(model)
        editor.insertText("committed", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.hasMarkedText())
        #expect(content.model?.revision == 2)
        #expect(events.last?["type"] as? String == "search" && events.last?["value"] as? String == "committed")
        #expect(events.last?["revision"] as? Int == 1)
    }
    @Test(.enabled("needs an awake display") { !NSScreen.screens.isEmpty })
    func childReopeningKeepsEditSequencesMonotonicBeforeAcknowledgment() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView = page
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var events: [[String: Any]] = []
        let host = DeclarativePopupHost(webView: page, zoom: { 1 }, send: { events.append($0) }, isAppActive: { true })
        defer { host.hide() }
        let field = NativePopupRow(id: "text", kind: .textField, label: "Text", value: "", editSequence: 0)
        let slider = NativePopupRow(id: "slider", kind: .slider, label: "Slider", value: "0", minimum: 0, maximum: 0, step: 1,
                                    slider: NativePopupSlider(stops: [NativePopupSliderStop(value: "only", label: "Only")]))
        var model = NativePopupModel(schemaVersion: 1, id: "same", revision: 1,
                                     anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                     side: .bottom, align: .start, width: 320,
                                     rows: [NativePopupRow(id: "parent", kind: .submenu, label: "Parent", children: [field, slider])])
        #expect(host.show(model)["shown"] as? Bool == true)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func content(in panel: NSWindow) throws -> NativePopupContent {
            let rootView = try #require(panel.contentView)
            return try #require(descendants(rootView).compactMap { $0 as? NativePopupContent }.first)
        }
        let panel = try #require(window.childWindows?.compactMap { $0 as? NativePopupPanel }.first)
        let root = try content(in: panel)
        func openChild() throws -> NativePopupContent {
            root.openSubmenu(model.rows[0], try #require(root.rowView(id: "parent")))
            return try content(in: #require(panel.childWindows?.compactMap { $0 as? NativePopupPanel }.first(where: { $0.isKeyWindow })))
        }
        let first = try openChild()
        let firstField = try #require(first.rowView(id: "text") as? NSTextField)
        firstField.stringValue = "first"
        first.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: firstField))
        let firstSequence = try #require(events.last?["editSequence"] as? Int)
        let retiredSlider = try #require(first.rowView(id: "slider") as? NativePopupSliderView)
        first.dismiss()
        retiredSlider.slider.commitValue(true)
        #expect(host.activeID == "same")
        let second = try openChild()
        let secondField = try #require(second.rowView(id: "text") as? NSTextField)
        #expect(secondField.stringValue == "first", "reopening must preserve an unacknowledged edit")
        secondField.stringValue = "second"
        second.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: secondField))
        let secondSequence = try #require(events.last?["editSequence"] as? Int)
        #expect(secondSequence > firstSequence)
        model.revision += 1
        model.rows[0].children?[0].value = "first"
        model.rows[0].children?[0].editSequence = firstSequence
        host.update(model)
        #expect((second.rowView(id: "text") as? NSTextField)?.stringValue == "second")
    }

    @Test func retiredRowsAndReentrantSliderCommitCannotActOnReplacement() throws {
        let content = NativePopupContent()
        let descriptor = NativePopupSlider(stops: [NativePopupSliderStop(value: "low", label: "Low"),
                                                   NativePopupSliderStop(value: "high", label: "High")], selectedValue: "low")
        var model = NativePopupModel(schemaVersion: 1, id: "same", revision: 1,
                                     anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                     side: .bottom, align: .start, width: 320,
                                     rows: [NativePopupRow(id: "slider", kind: .slider, label: "Slider", value: "0", minimum: 0, maximum: 1, step: 1, slider: descriptor),
                                            NativePopupRow(id: "action", kind: .action, label: "Old action"),
                                            NativePopupRow(id: "toggle", kind: .toggle, label: "Toggle")])
        content.update(model)
        let oldSlider = try #require(content.rowView(id: "slider") as? NativePopupSliderView)
        let oldAction = try #require(content.rowView(id: "action") as? PopupRowView)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let oldToggle = try #require(descendants(content).compactMap { $0 as? NSSwitch }.first)
        let oldTarget = try #require(oldToggle.target as? NativePopupControlTarget)
        var events = 0
        var closes = 0
        content.emit = { _, _, _ in events += 1 }
        content.commit = { closes += 1 }
        content.dismiss = { closes += 1 }
        model.revision += 1
        model.rows[0].slider?.stops[1].value = "replacement"
        model.rows[1].label = "Replacement action"
        content.update(model)
        oldSlider.slider.doubleValue = 1
        oldSlider.slider.commitValue(true)
        oldSlider.escape()
        _ = oldSlider.slider.navigate(125)
        oldAction.onHover?()
        oldAction.onActivate?()
        oldTarget.controlChanged(oldToggle)
        #expect(events == 0 && closes == 0)
        let current = try #require(content.rowView(id: "slider") as? NativePopupSliderView)
        content.emit = { _, _, _ in
            events += 1
            content.beginPresentation()
            var replacement = model
            replacement.id = "replacement"
            content.update(replacement)
        }
        current.slider.doubleValue = 1
        current.slider.commitValue(true)
        #expect(events == 1 && closes == 0)
        #expect(content.model?.id == "replacement")
    }

    @Test(arguments: [false, true])
    func sliderEchoKeepsControlAndEnterDismissal(_ structural: Bool) throws {
        let content = NativePopupContent()
        let spec = NativePopupSlider(stops: [NativePopupSliderStop(value: "low", label: "Low"),
                                            NativePopupSliderStop(value: "high", label: "High")], selectedValue: "low")
        var model = NativePopupModel(schemaVersion: 1, id: "same", revision: 1,
                                     anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                     side: .bottom, align: .start, width: 320,
                                     rows: [NativePopupRow(id: "slider", kind: .slider, label: "Slider", value: "0", minimum: 0, maximum: 1, step: 1, slider: spec)])
        content.update(model)
        let slider = try #require(content.rowView(id: "slider") as? NativePopupSliderView)
        var closes = 0
        content.commit = { closes += 1 }
        content.emit = { _, _, value in
            model.revision += 1
            model.rows[0].value = value
            model.rows[0].slider?.selectedValue = "high"
            if structural { model.title = "Updated" }
            content.update(model)
        }
        slider.slider.doubleValue = 1
        slider.slider.commitValue(true)
        #expect((content.rowView(id: "slider") === slider) == !structural)
        #expect(closes == 1)
    }

    @Test(.enabled("needs an awake display") { !NSScreen.screens.isEmpty })
    func replacementDismissalCannotOverwriteAReentrantPresentation() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView = page
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var model = NativePopupModel(schemaVersion: 1, id: "old", revision: 1,
                                     anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                     side: .bottom, align: .start, width: 320, rows: [])
        var reentrant = model
        reentrant.id = "newest"
        var events: [[String: Any]] = []
        var host: DeclarativePopupHost!
        host = DeclarativePopupHost(webView: page, zoom: { 1 }, send: { event in
            events.append(event)
            if events.count == 1 { _ = host.show(reentrant) }
        }, isAppActive: { true })
        defer { host.hide() }
        #expect(host.show(model)["shown"] as? Bool == true)
        model.id = "outer"
        _ = host.show(model)
        #expect(host.activeID == "newest")
        #expect(events.count == 1)
    }

    @Test(.enabled("needs an awake display") { !NSScreen.screens.isEmpty })
    func actionEchoStillDismissesTheSameOpening() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView = page
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var model = NativePopupModel(schemaVersion: 1, id: "same", revision: 1,
                                     anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                     side: .bottom, align: .start, width: 320,
                                     rows: [NativePopupRow(id: "action", kind: .action, label: "Action")])
        var events: [String] = []
        var host: DeclarativePopupHost!
        host = DeclarativePopupHost(webView: page, zoom: { 1 }, send: { event in
            if let type = event["type"] as? String { events.append(type) }
            if ["pick", "dismiss"].contains(event["type"] as? String ?? "") { model.revision += 1; host.update(model) }
        }, isAppActive: { true })
        defer { host.hide() }
        #expect(host.show(model)["shown"] as? Bool == true)
        let panel = try #require(window.childWindows?.compactMap { $0 as? NativePopupPanel }.first)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let rootView = try #require(panel.contentView)
        let content = try #require(descendants(rootView).compactMap { $0 as? NativePopupContent }.first)
        let action = try #require(content.rowView(id: "action") as? PopupRowView)
        action.onActivate?()
        #expect(events == ["pick", "dismiss"])
        #expect(host.activeID == nil)
    }

    @Test(.enabled("needs an awake display") { !NSScreen.screens.isEmpty }, arguments: ["replace", "dismiss", "legacy", "hide", "owner"])
    func legacyReplacementCannotOverwriteAReentrantDeclaration(_ operation: String) throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView = page
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func declaration(_ id: String) throws -> WebPopupHost.Model {
            try #require(WebPopupHost.Model([
                "schemaVersion": 1, "id": id, "revision": 1,
                "anchor": ["left": 0, "top": 0, "right": 20, "bottom": 20],
                "side": "bottom", "align": "start", "width": 320, "rows": []
            ]))
        }
        let newest = try declaration("newest")
        let legacy = try #require(WebPopupHost.Model([
            "items": [["id": "old", "label": "Old"]],
            "anchor": ["left": 0, "top": 0, "right": 20, "bottom": 20]
        ]))
        var count = 0
        var host: WebPopupHost!
        host = WebPopupHost(webView: page, zoom: { 1 }, send: { _ in
            count += 1
            if count == 1 {
                if operation == "legacy" { _ = host.show(legacy) }
                else if operation == "hide" { host.hideRequest([:]) }
                else if operation == "owner" { host.dismiss() }
                else { _ = host.show(newest) }
            }
        })
        defer { host.hide() }
        #expect(host.show(legacy)["shown"] as? Bool == true)
        if operation == "dismiss" { host.dismiss() } else { _ = host.show(try declaration("outer")) }
        if operation == "owner" { #expect(host.shownFrame == nil && count == 1); return }
        let panel = try #require(window.childWindows?.compactMap { $0 as? NativePopupPanel }.first)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let rootView = try #require(panel.contentView)
        let content = try #require(descendants(rootView).compactMap { $0 as? NativePopupContent }.first)
        #expect(content.model?.id == (["legacy", "hide"].contains(operation) ? "outer" : "newest") && count == 1)
    }

    @Test(.enabled("needs an awake display") { !NSScreen.screens.isEmpty })
    func declarativeOwnerDismissalPreservesReentrantLegacyMenu() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView = page
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let declaration = try #require(WebPopupHost.Model([
            "schemaVersion": 1, "id": "old", "revision": 1,
            "anchor": ["left": 0, "top": 0, "right": 20, "bottom": 20],
            "side": "bottom", "align": "start", "width": 320, "rows": []
        ]))
        let legacy = try #require(WebPopupHost.Model([
            "items": [["id": "new", "label": "New"]],
            "anchor": ["left": 0, "top": 0, "right": 20, "bottom": 20]
        ]))
        var count = 0
        var host: WebPopupHost!
        host = WebPopupHost(webView: page, zoom: { 1 }, send: { _ in
            count += 1
            if count == 1 { _ = host.show(legacy) }
        })
        defer { host.hide() }
        #expect(host.show(declaration)["shown"] as? Bool == true)
        host.dismiss()
        #expect(count == 1 && host.shownFrame != nil)
    }

    @Test func newerDescriptorRetiresAnObsoleteDeferredComposition() throws {
        let content = NativePopupContent()
        var model = NativePopupModel(schemaVersion: 1, id: "same", revision: 1,
                                     anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                     side: .bottom, align: .start, width: 320, rows: [],
                                     search: NativePopupField(id: "query", value: "", placeholder: "Search"))
        content.update(model)
        model.revision = 2; model.title = "Deferred"
        content.pendingCompositionModel = model
        model.revision = 3; model.title = "Newest"
        content.update(model)
        let field = try #require(content.search)
        field.stringValue = "typed"
        content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(content.model?.revision == 3 && content.model?.title == "Newest")
    }

}
