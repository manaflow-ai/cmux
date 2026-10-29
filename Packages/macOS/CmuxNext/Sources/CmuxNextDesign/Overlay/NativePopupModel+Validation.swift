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
              [anchor.left, anchor.top, anchor.right, anchor.bottom].allSatisfy(\.isFinite),
              anchor.right >= anchor.left, anchor.bottom >= anchor.top else { return false }
        var identifiers = Set<String>()
        if let search {
            guard !search.id.isEmpty, search.value.count <= 100_000 else { return false }
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
            for action in row.actions ?? [] {
                guard !action.id.isEmpty, identifiers.insert(action.id).inserted else { return false }
            }
            if row.kind == .slider {
                guard let minimum = row.minimum, let maximum = row.maximum,
                      minimum.isFinite, maximum.isFinite, minimum < maximum,
                      row.step.map({ $0.isFinite && $0 > 0 }) ?? true else { return false }
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
