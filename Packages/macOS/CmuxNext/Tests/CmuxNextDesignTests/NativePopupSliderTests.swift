import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

@MainActor @Suite(.serialized, .closesItsWindows) struct NativePopupSliderTests {
    private func descriptor(style: NativePopupSliderStyle = .accent) -> NativePopupSlider {
        NativePopupSlider(stops: [NativePopupSliderStop(value: "low", label: "Low"),
                                 NativePopupSliderStop(value: "high", label: "High", description: "More careful", accessibilityLabel: "High, recommended")],
                          selectedValue: "automatic", defaultValue: "high", recommendedValue: "high",
                          recommendedLabel: "Recommended: High", minimumLabel: "Faster", maximumLabel: "Smarter",
                          accessibilityLabel: "Effort", style: style)
    }

    private func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                        isARepeat: false, keyCode: code)!
    }

    @Test func namedStopsRestWithoutCommittingAndEnterCommitsOnce() throws {
        let spec = descriptor()
        let row = NativePopupRow(id: "effort", kind: .slider, label: "Reasoning", value: "1", minimum: 0, maximum: 1, step: 1, slider: spec)
        let view = NativePopupSliderView(row: row, descriptor: spec)
        var values: [String] = []
        var closes = 0
        view.change = { values.append($0) }
        view.commit = { closes += 1 }
        #expect(values.isEmpty)
        #expect(view.slider.doubleValue == 1)
        #expect(view.currentLabel.stringValue == "High")
        #expect(view.currentLabel.themedToolTip == "More careful")
        #expect(view.slider.accessibilityLabel() == "Effort")
        #expect(view.slider.accessibilityValueDescription() == "High, recommended")
        view.slider.keyDown(with: key(36))
        #expect(values == ["1"])
        #expect(closes == 1)
        view.slider.keyDown(with: key(36))
        #expect(values == ["1"])
        view.slider.keyDown(with: key(123))
        #expect(values == ["1", "0"])
        #expect(view.currentLabel.stringValue == "Low")
        #expect(closes == 2)
    }

    @Test func numericPositionOverridesNamedRestingIdentity() {
        var spec = descriptor()
        spec.selectedValue = "high"
        let row = NativePopupRow(id: "effort", kind: .slider, label: "Reasoning", value: "0", minimum: 0, maximum: 1, step: 1, slider: spec)
        let view = NativePopupSliderView(row: row, descriptor: spec)
        var values: [String] = []
        view.change = { values.append($0) }
        #expect(view.slider.doubleValue == 0 && view.currentLabel.stringValue == "Low")
        #expect(values.isEmpty)
        view.slider.keyDown(with: key(36))
        #expect(values == ["0"])
    }

    @Test func numericSliderReceivesInitialKeyboardFocus() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NativePopupContent()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        defer { window.closeAfterTest() }
        let model = NativePopupModel(schemaVersion: 1, id: "numeric", revision: 1,
                                     anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                     side: .bottom, align: .start, width: 320,
                                     rows: [NativePopupRow(id: "slider", kind: .slider, label: "Value", value: "0", minimum: 0, maximum: 1, step: 1)])
        content.update(model)
        content.focusInitial()
        #expect(window.firstResponder is NSSlider)
    }

    @Test func selectedValueWinsOverDefaultAndDisabledSliderEmitsNothing() {
        var spec = descriptor()
        spec.selectedValue = "low"
        let row = NativePopupRow(id: "effort", kind: .slider, label: "Reasoning", disabled: true, value: "0", minimum: 0, maximum: 1, step: 1, slider: spec)
        let view = NativePopupSliderView(row: row, descriptor: spec)
        var values: [String] = []
        var closes = 0
        view.change = { values.append($0) }
        view.commit = { closes += 1 }
        #expect(view.slider.doubleValue == 0)
        view.slider.keyDown(with: key(124))
        view.slider.keyDown(with: key(36))
        view.slider.commitValue(false)
        #expect(values.isEmpty)
        #expect(closes == 0)
    }

    @Test(arguments: ["absent", "enabled", "disabled"])
    func verticalArrowsTravelToFollowingActionsAndBackWithoutChangingEffort(searchState: String) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NativePopupContent()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        defer { window.closeAfterTest() }
        let spec = descriptor()
        var model = NativePopupModel(schemaVersion: 1, id: "effort", revision: 1,
                                     anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                     side: .bottom, align: .start, width: 320,
                                     rows: [NativePopupRow(id: "slider", kind: .slider, label: "Reasoning", minimum: 0, maximum: 1, step: 1, slider: spec),
                                            NativePopupRow(id: "heading", kind: .section, label: "Speed"),
                                            NativePopupRow(id: "disabled", kind: .action, label: "Disabled", disabled: true),
                                            NativePopupRow(id: "off", kind: .action, label: "Off"),
                                            NativePopupRow(id: "on", kind: .action, label: "On")])
        if searchState != "absent" {
            model.search = NativePopupField(id: "query", value: "", placeholder: "Search", disabled: searchState == "disabled")
        }
        content.update(model)
        content.focusInitial()
        let view = try #require(content.rowView(id: "slider") as? NativePopupSliderView)
        if searchState == "enabled" { #expect(window.makeFirstResponder(view.slider)) }
        #expect(window.firstResponder === view.slider)
        var changes: [String?] = []
        var highlights: [String?] = []
        content.emit = { type, id, value in
            if type == .change { changes.append(value) }
            if type == .highlight { highlights.append(id) }
        }
        view.slider.keyDown(with: key(126))
        #expect(window.firstResponder === view.slider && changes.isEmpty)
        view.slider.keyDown(with: key(125))
        #expect(window.firstResponder === content && highlights.last == "off" && changes.isEmpty)
        content.keyDown(with: key(126))
        #expect(window.firstResponder === view.slider && changes.isEmpty)
        view.slider.keyDown(with: key(123))
        #expect(changes == ["0"])
        model.rows = [model.rows[0]]
        content.update(model)
        let standalone = try #require(content.rowView(id: "slider") as? NativePopupSliderView)
        standalone.slider.keyDown(with: key(125))
        #expect(standalone.slider.doubleValue == 0, "without following actions vertical arrows still adjust the range")
    }

    @Test func descriptorRoundTripsAndNativeStylesRenderDistinctly() throws {
        var rasters = Set<Data>()
        for style in [NativePopupSliderStyle.accent, .minimal] {
            let spec = descriptor(style: style)
            let row = NativePopupRow(id: "effort", kind: .slider, label: "Reasoning", value: "1", minimum: 0, maximum: 1, step: 1, slider: spec)
            let decoded = try JSONDecoder().decode(NativePopupRow.self, from: JSONEncoder().encode(row))
            #expect(decoded.slider == spec)
            let view = NativePopupSliderView(row: decoded, descriptor: try #require(decoded.slider))
            view.frame = NSRect(x: 0, y: 0, width: 120, height: view.preferredHeight)
            view.layoutSubtreeIfNeeded()
            #expect(view.slider.frame.maxX <= view.bounds.maxX)
            let texts = view.subviews.compactMap { ($0 as? ThemedLabel)?.stringValue }
            #expect(texts.contains("Faster") && texts.contains("Smarter") && texts.contains("Recommended: High"))
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            rasters.insert(try #require(bitmap.representation(using: .png, properties: [:])))
        }
        #expect(rasters.count == 2)
    }
}
