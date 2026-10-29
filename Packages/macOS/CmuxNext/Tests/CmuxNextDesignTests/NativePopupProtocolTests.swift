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
