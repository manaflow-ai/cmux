import AppKit
@testable import CmuxNextDesign
import CmuxNextIcons
import Testing

@MainActor @Suite(.serialized) struct NativePopupContentTests {
    @Test func searchDescriptorUpdatesWithoutChangingItsIdentity() throws {
        let content = NativePopupContent()
        var model = Self.model()
        model.search = NativePopupField(id: "query", value: "a", placeholder: "Search")
        content.update(model)
        let field = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        model.revision += 1
        model.search = NativePopupField(id: "query", value: "b", placeholder: "Unavailable", disabled: true)
        content.update(model)
        #expect(field.stringValue == "b")
        #expect(field.placeholderString == "Unavailable")
        #expect(!field.isEnabled)
    }

    @Test(arguments: [true, false])
    func descriptorRebuildPreservesAndClampsTheTextSelection(isSearch: Bool) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NativePopupContent()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var model = Self.model()
        if isSearch { model.search = NativePopupField(id: "query", value: "A😀BCDE", placeholder: "Search") }
        else { model.rows = [NativePopupRow(id: "query", kind: .textField, label: "Value", value: "A😀BCDE")] }
        content.update(model)
        let original = try #require(content.subviews.compactMap { $0 as? NSTextField }.first)
        #expect(window.makeFirstResponder(original))
        let editor = try #require(original.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 1, length: 4))
        model.title = "Changed title"
        content.update(model)
        let replacement = try #require(content.subviews.compactMap { $0 as? NSTextField }.first { $0.currentEditor() != nil })
        let after = try #require(replacement.currentEditor() as? NSTextView)
        #expect(after.selectedRange() == NSRange(location: 1, length: 4))
        model.title = "Shorter value"
        if isSearch { model.search?.value = "A😀" } else { model.rows[0].value = "A😀" }
        content.update(model)
        let shorter = try #require(content.subviews.compactMap { $0 as? NSTextField }.first { $0.currentEditor() != nil })
        let shorterEditor = try #require(shorter.currentEditor() as? NSTextView)
        #expect(shorterEditor.selectedRange() == NSRange(location: 1, length: 2))
    }

    @Test func accessoryActionKeepsFocusAndActivationAcrossDescriptorRebuild() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NativePopupContent()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var model = Self.model()
        model.rows[0].actions = [NativePopupAction(id: "accessory", label: "Accessory", keepOpen: true)]
        content.update(model)
        let original = try #require(Self.descendants(of: content).compactMap { $0 as? NSButton }.first)
        #expect(window.makeFirstResponder(original))
        var picked: [String?] = []
        content.emit = { type, id, _ in if type == .pick { picked.append(id) } }
        original.performClick(nil)
        model.title = "Changed title"
        content.update(model)
        let replacement = try #require(Self.descendants(of: content).compactMap { $0 as? NSButton }.first)
        #expect(replacement !== original && window.firstResponder === replacement)
        let focused = try #require(window.firstResponder as? NSButton)
        focused.performClick(nil)
        #expect(picked == ["accessory", "accessory"])
    }

    @Test func documentTracksAClampedViewport() {
        let viewport = NSClipView(frame: NSRect(x: 0, y: 0, width: 180, height: 120))
        let content = NativePopupContent(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        viewport.documentView = content
        content.update(Self.model())
        content.layout()
        #expect(content.frame.width == viewport.bounds.width)
        #expect(content.subviews.allSatisfy { $0.frame.maxX <= viewport.bounds.width })
    }

    @Test func sliderFitsInsideANarrowRow() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NativePopupContent()
        window.contentView = content
        defer { window.orderOut(nil) }
        var model = Self.model()
        model.width = 120
        model.rows = [NativePopupRow(id: "slider", kind: .slider, label: "Value", value: "0.5", minimum: 0, maximum: 1)]
        content.update(model)
        content.layoutSubtreeIfNeeded()
        let slider = try #require(Self.descendants(of: content).compactMap { $0 as? NSSlider }.first)
        let frame = content.convert(slider.bounds, from: slider)
        #expect(frame.minX >= 0 && frame.maxX <= content.bounds.width)
        #expect(frame.width > 0)
    }

    @Test func iconRowsKeepTheirCheckmarkAndSharedColumns() throws {
        let content = NativePopupContent(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        var model = Self.model()
        model.rows = [NativePopupRow(id: "selected", kind: .action, label: "Selected", icon: "permission.ask", checked: true),
                      NativePopupRow(id: "other", kind: .action, label: "Other", icon: "permission.auto", checked: false)]
        content.update(model)
        content.layoutSubtreeIfNeeded()
        let selected = try #require(content.rowView(id: "selected") as? PopupRowView)
        let other = try #require(content.rowView(id: "other") as? PopupRowView)
        let columns = try #require(selected.leadingView as? NSStackView)
        let otherColumns = try #require(other.leadingView as? NSStackView)
        #expect((columns.arrangedSubviews.first as? ThemedLabel)?.stringValue == "✓")
        #expect(columns.arrangedSubviews.first?.isHidden == false)
        #expect(otherColumns.arrangedSubviews.first?.isHidden == true)
        #expect(columns.arrangedSubviews.last is NSImageView)
        #expect(selected.rowLayout.leadingColumn == other.rowLayout.leadingColumn)
        #expect(content.convert(selected.titleLabel.bounds, from: selected.titleLabel).minX ==
                content.convert(other.titleLabel.bounds, from: other.titleLabel).minX)
    }

    @Test func permissionModeGlyphsRenderDistinctly() throws {
        var drawings = Set<Data>()
        for name in [IconName.permissionAsk, .permissionAuto, .permissionFullAccess, .permissionShield, .permissionChecked] {
            #expect(IconCatalog.bundled.entry(for: name) != nil)
            let image = try #require(CGImage.icon(name, size: 16, scale: 2, tint: CGColor(gray: 0, alpha: 1)))
            let pixels = try #require(image.dataProvider?.data) as Data
            #expect(pixels.contains { $0 != 0 }, "the mode glyph is empty")
            drawings.insert(pixels)
        }
        #expect(drawings.count == 5, "the five modes must keep their distinct existing glyphs")
    }

    @Test(arguments: ["rows", "rail", "footer"])
    func committedCompositionSurvivesADeferredDescriptorUpdate(location: String) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NativePopupContent()
        window.contentView = content
        defer { window.orderOut(nil) }
        var model = Self.model()
        let row = NativePopupRow(id: "name", kind: .textField, label: "Name", value: "")
        switch location {
        case "rail": model.rail = [row]
        case "footer": model.footer = [row]
        default: model.rows = [row]
        }
        var changes: [String] = []
        content.emit = { type, id, value in
            if type == .change, id == "name", let value { changes.append(value) }
        }
        content.update(model)
        let field = try #require(content.subviews.compactMap { $0 as? NSTextField }.first)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        model.revision += 1
        model.title = "Updated while composing"
        content.update(model)
        #expect(field.superview === content)
        editor.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.hasMarkedText())
        let replacement = try #require(content.subviews.compactMap { $0 as? NSTextField }
            .first { $0.isEditable })
        #expect(replacement !== field)
        #expect(replacement.stringValue == "日本")
        #expect(changes.last == "日本")
        #expect(model.rows.first(where: { $0.id == "name" })?.value != "日本")
    }

    @Test(arguments: [NativePopupRowKind.choice, .slider])
    func keyboardActivationFocusesTheEditableControl(kind: NativePopupRowKind) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NativePopupContent()
        window.contentView = content
        defer { window.orderOut(nil) }
        var model = Self.model()
        model.rows = [NativePopupRow(id: "control", kind: kind, label: "Control", value: "0",
                                    options: [NativePopupOption(id: "0", label: "First"), NativePopupOption(id: "1", label: "Second")])]
        content.update(model)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(content)
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: 0, windowNumber: window.windowNumber,
                                                context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                isARepeat: false, keyCode: 36))
        content.keyDown(with: enter)
        if kind == .choice { #expect(window.firstResponder is NSSegmentedControl) }
        else { #expect(window.firstResponder is NSSlider) }
    }

    @Test(arguments: [NativePopupRowKind.choice, .slider, .toggle])
    func descriptorRebuildKeepsTheFocusedEditableControl(kind: NativePopupRowKind) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NativePopupContent()
        window.contentView = content
        defer { window.orderOut(nil) }
        var model = Self.model()
        model.rows = [NativePopupRow(id: "control", kind: kind, label: "Control", value: kind == .choice ? "0" : "0",
                                     options: kind == .choice ? [NativePopupOption(id: "0", label: "First"),
                                                                 NativePopupOption(id: "1", label: "Second")] : nil,
                                     minimum: kind == .slider ? 0 : nil, maximum: kind == .slider ? 1 : nil)]
        content.update(model)
        window.makeKeyAndOrderFront(nil)
        let original = try #require(Self.descendants(of: content).first { $0 is NSSegmentedControl || $0 is NSSlider || $0 is NSSwitch })
        #expect(window.makeFirstResponder(original))
        model.revision += 1
        model.rows[0].value = kind == .choice ? "1" : "0.5"
        if kind == .toggle { model.rows[0].checked = true }
        content.update(model)
        let replacement = try #require(Self.descendants(of: content).first { $0 is NSSegmentedControl || $0 is NSSlider || $0 is NSSwitch })
        if kind == .slider { #expect(replacement === original, "a value echo must preserve slider tracking") }
        else { #expect(replacement !== original) }
        #expect(window.firstResponder === replacement, "the descriptor update dropped control focus")
        model.rows[0].label = "Structurally changed"
        content.update(model)
        let rebuilt = try #require(Self.descendants(of: content).first { $0 is NSSegmentedControl || $0 is NSSlider || $0 is NSSwitch })
        #expect(rebuilt !== replacement && window.firstResponder === rebuilt)
    }

    @Test func sliderStepRoundingStaysWithinItsBounds() throws {
        let content = NativePopupContent()
        var model = Self.model()
        model.rows = [NativePopupRow(id: "slider", kind: .slider, label: "Slider", value: "0",
                                    minimum: 0, maximum: 1, step: 0.6)]
        var value: String?
        content.emit = { type, id, next in if type == .change, id == "slider" { value = next } }
        content.update(model)
        let slider = try #require(Self.descendants(of: content).compactMap { $0 as? NSSlider }.first)
        slider.doubleValue = 1
        let sent = slider.sendAction(slider.action, to: slider.target)
        #expect(sent)
        #expect(value.flatMap(Double.init) == 1)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @Test func menuSelectionOwnsActionRowKeyboardActivation() throws {
        let content = NativePopupContent()
        var model = Self.model()
        model.rows.append(NativePopupRow(id: "next", kind: .action, label: "Next"))
        var picked: String?
        content.emit = { type, id, _ in if type == .pick { picked = id } }
        content.update(model)
        let row = try #require(content.rowView(id: "pick"))
        #expect(!row.acceptsFirstResponder && !row.canBecomeKeyView,
                "a row wrapper must not retain Return/Space while the menu highlight moves")
        for code: UInt16 in [125, 36] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                     timestamp: 0, windowNumber: 0, context: nil,
                                                     characters: "", charactersIgnoringModifiers: "",
                                                     isARepeat: false, keyCode: code))
            content.keyDown(with: event)
        }
        #expect(picked == "next")
    }

    @Test func repeatedKeyboardToggleFlipsTheSwitchEachTime() throws {
        let content = NativePopupContent()
        var model = Self.model()
        model.rows = [NativePopupRow(id: "toggle", kind: .toggle, label: "Toggle", checked: false)]
        var changes: [String?] = []
        content.emit = { type, id, value in if type == .change, id == "toggle" { changes.append(value) } }
        content.update(model)
        let control = try #require(Self.descendants(of: content).compactMap { $0 as? NSSwitch }.first)
        for code: UInt16 in [125, 36, 36] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                     timestamp: 0, windowNumber: 0, context: nil,
                                                     characters: "", charactersIgnoringModifiers: "",
                                                     isARepeat: false, keyCode: code))
            content.keyDown(with: event)
        }
        #expect(changes == ["true", "false"], "a second Return before the page echoes must flip back, not resend")
        #expect(control.state == .off)
    }

    @Test func ordinaryTextFieldReturnDoesNotActivateTheHighlightedAction() throws {
        let content = NativePopupContent()
        var model = Self.model()
        model.rows.append(NativePopupRow(id: "name", kind: .textField, label: "Name", value: "Edited"))
        var picked: String?
        content.emit = { type, id, _ in if type == .pick { picked = id } }
        content.update(model)
        let field = try #require(content.rowView(id: "name") as? NSTextField)
        let consumed = content.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(!consumed)
        #expect(picked == nil)
    }

    @Test func numberedShortcutPicksOnlyAnEnabledActionRow() throws {
        let content = NativePopupContent()
        var model = Self.model()
        model.rows = [NativePopupRow(id: "disabled", kind: .action, label: "Disabled", shortcut: "1", disabled: true),
                      NativePopupRow(id: "pick", kind: .action, label: "Pick", shortcut: "2")]
        var picked: String?
        content.emit = { type, id, _ in if type == .pick { picked = id } }
        content.update(model)
        let two = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, characters: "2", charactersIgnoringModifiers: "2",
                                                isARepeat: false, keyCode: 19))
        content.keyDown(with: two)
        #expect(picked == "pick")
        picked = nil
        let one = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, characters: "1", charactersIgnoringModifiers: "1",
                                                isARepeat: false, keyCode: 18))
        content.keyDown(with: one)
        #expect(picked == nil)
    }

    private static func model() -> NativePopupModel {
        NativePopupModel(schemaVersion: 1, id: "content", revision: 1,
                         anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                         side: .bottom, align: .start, width: 320,
                         rows: [NativePopupRow(id: "pick", kind: .action, label: "Pick")])
    }
}
