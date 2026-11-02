import Foundation
@testable import CmuxNextDesign
import Testing

@MainActor struct NativePopupProtocolTests {
    @Test func richRowsRoundTripWithoutFlattening() throws {
        let model = Self.model()
        let data = try JSONEncoder().encode(model)
        let params = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(NativePopupModel.decode(params) == model)
        let bridged = try #require(WebPopupHost.Model(params))
        #expect(bridged.declaration == model)
        #expect(bridged.instant)
    }

    @Test func malformedIdentityAndGeometryAreRejected() {
        var model = Self.model()
        model.width = .infinity
        #expect(!model.isValid)
        model = Self.model()
        model.rows.append(model.rows[0])
        #expect(!model.isValid)
        model = Self.model()
        model.revision = -1
        #expect(!model.isValid)
        model = Self.model()
        model.rows[0].actions = [NativePopupAction(id: model.rows[0].id, label: "Duplicate")]
        #expect(!model.isValid)
    }

    @Test func invalidSliderAndChoiceAreRejected() {
        var model = Self.model()
        model.rows = [NativePopupRow(id: "effort", kind: .slider, label: "Effort", minimum: 1, maximum: 1)]
        #expect(!model.isValid)
        model.rows = [NativePopupRow(id: "effort", kind: .choice, label: "Effort", options: [])]
        #expect(!model.isValid)
    }

    @Test func namedSliderRejectsDuplicateStopsAndMismatchedRange() {
        var model = Self.model()
        model.footer = nil
        let stop = NativePopupSliderStop(value: "only", label: "Only")
        model.rows = [NativePopupRow(id: "effort", kind: .slider, label: "Effort", value: "0",
                                     minimum: 0, maximum: 0, step: 1, slider: NativePopupSlider(stops: [stop]))]
        #expect(model.isValid)
        for value in ["-1", "1", "0.5", "nan", "not a number"] {
            model.rows[0].value = value
            #expect(!model.isValid)
        }
        model.rows[0].value = "0"
        model.rows[0].slider?.stops.append(stop)
        #expect(!model.isValid)
        model.rows[0].slider?.stops = [stop]
        model.rows[0].maximum = 2
        #expect(!model.isValid)
    }

    @Test func completionMetadataIsBoundedAndOnlyValidOnActionRows() {
        var model = Self.model()
        model.rows = [NativePopupRow(id: "suggestion", kind: .action, label: "Suggestion", value: "opaque", completion: "Named suggestion")]
        #expect(model.isValid)
        model.rows[0].kind = .text
        #expect(!model.isValid)
        model.rows[0].kind = .action
        model.rows[0].completion = String(repeating: "x", count: 100_001)
        #expect(!model.isValid)
    }

    @Test func hugeAnchorsAndNonNumericPlainSliderValuesAreRejected() {
        var model = Self.model()
        model.anchor = NativePopupAnchor(left: -Double.greatestFiniteMagnitude, top: 0,
                                         right: Double.greatestFiniteMagnitude, bottom: 10)
        #expect(!model.isValid, "right - left overflows to infinity in the host")
        model = Self.model()
        model.rows = [NativePopupRow(id: "volume", kind: .slider, label: "Volume", value: "0.5", minimum: 0, maximum: 1)]
        #expect(model.isValid)
        for bad in ["nan", "inf", "-infinity", "loud"] {
            model.rows[0].value = bad
            #expect(!model.isValid, "\(bad) would reach NSSlider")
        }
    }

    private static func model() -> NativePopupModel {
        NativePopupModel(schemaVersion: 1, id: "model-picker", revision: 2,
                         anchor: NativePopupAnchor(left: 20, top: 30, right: 120, bottom: 60),
                         side: .top, align: .start, width: 320,
                         rows: [NativePopupRow(id: "model:a", kind: .action, label: "Model A", description: "Current account",
                                               actions: [NativePopupAction(id: "favorite:a", label: "Favorite", keepOpen: true)])],
                         search: NativePopupField(id: "query", value: "", placeholder: "Search models"),
                         rail: [NativePopupRow(id: "harness:a", kind: .action, label: "Harness A", keepOpen: true)], railWidth: 44,
                         footer: [NativePopupRow(id: "effort", kind: .choice, label: "Effort", value: "high",
                                                options: [NativePopupOption(id: "high", label: "High")])])
    }
}
