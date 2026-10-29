import AppKit
@testable import CmuxNextDesign
import Testing

@MainActor @Suite(.serialized) struct NativePopupSliderTests {
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
        #expect(view.currentLabel.toolTip == "More careful")
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
