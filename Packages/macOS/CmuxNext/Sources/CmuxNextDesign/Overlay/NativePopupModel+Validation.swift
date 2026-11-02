import Foundation

extension NativePopupModel {
    /// Decodes the generated wire model without silently dropping unsupported rows.
    public static func decode(_ params: [String: Any]) -> NativePopupModel? {
        guard JSONSerialization.isValidJSONObject(params),
              let data = try? JSONSerialization.data(withJSONObject: params),
              let model = try? JSONDecoder().decode(Self.self, from: data), model.isValid else { return nil }
        return model
    }

    /// The host rejects malformed identities, geometry and recursive control descriptions.
    public var isValid: Bool {
        guard schemaVersion == 1, !id.isEmpty, id.count <= 128, revision >= 0,
              width.isFinite, width >= 120, width <= 1200,
              // Bounded so the host's anchor width/height and zoom scaling stay finite in AppKit.
              [anchor.left, anchor.top, anchor.right, anchor.bottom].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
              anchor.right >= anchor.left, anchor.bottom >= anchor.top else { return false }
        var identifiers = Set<String>()
        if let search {
            guard !search.id.isEmpty, search.value.count <= 100_000 else { return false }
            guard search.editSequence.map({ $0 >= 0 && $0 < 9_007_199_254_740_991 }) ?? true else { return false }
            identifiers.insert(search.id)
        }
        guard railWidth.map({ $0.isFinite && $0 >= 40 && $0 <= width / 2 }) ?? true else { return false }
        return Self.validate((rail ?? []) + rows + (footer ?? []), depth: 0, identifiers: &identifiers)
    }

    private static func validate(_ rows: [NativePopupRow], depth: Int, identifiers: inout Set<String>) -> Bool {
        guard depth <= 16, rows.count <= 1000 else { return false }
        for row in rows {
            guard !row.id.isEmpty, row.id.count <= 128, identifiers.insert(row.id).inserted,
                  row.label.count <= 10_000 else { return false }
            guard row.editSequence.map({ $0 >= 0 && $0 < 9_007_199_254_740_991 && row.kind == .textField }) ?? true else { return false }
            if let completion = row.completion {
                guard row.kind == .action, completion.count <= 100_000 else { return false }
            }
            for action in row.actions ?? [] {
                guard !action.id.isEmpty, identifiers.insert(action.id).inserted else { return false }
            }
            if row.kind == .slider {
                guard let minimum = row.minimum, let maximum = row.maximum,
                      minimum.isFinite, maximum.isFinite, (minimum < maximum || (row.slider?.stops.count == 1 && minimum == 0 && maximum == 0)),
                      row.step.map({ $0.isFinite && $0 > 0 }) ?? true else { return false }
                // A plain slider's value goes straight into NSSlider: it must be a finite number.
                if row.slider == nil, let value = row.value {
                    guard let number = Double(value), number.isFinite else { return false }
                }
            }
            if let slider = row.slider {
                let values = slider.stops.map(\.value)
                guard row.kind == .slider, !values.isEmpty, values.count <= 100,
                      values.allSatisfy({ !$0.isEmpty }), Set(values).count == values.count,
                      row.minimum == 0, row.maximum == Double(values.count - 1), row.step == 1 else { return false }
                if let value = row.value {
                    guard let index = Int(value), slider.stops.indices.contains(index) else { return false }
                }
            }
            if row.kind == .choice {
                let options = row.options ?? []
                guard !options.isEmpty, Set(options.map(\.id)).count == options.count else { return false }
            }
            if let children = row.children, !validate(children, depth: depth + 1, identifiers: &identifiers) { return false }
        }
        return identifiers.count <= 4000
    }
}
