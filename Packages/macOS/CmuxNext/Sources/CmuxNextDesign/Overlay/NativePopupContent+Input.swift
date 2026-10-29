import AppKit

extension NativePopupContent {
    func preservingLocalEdits(in incoming: NativePopupModel) -> NativePopupModel {
        var next = incoming
        let rows = next.rows + (next.rail ?? []) + (next.footer ?? [])
        let activeIDs = Set(rows.flatMap { flattenIDs($0) } + (next.search.map { [$0.id] } ?? []))
        localFieldValues = localFieldValues.filter { activeIDs.contains($0.key) }
        if let field = next.search, field.disabled == true { localFieldValues.removeValue(forKey: field.id) }
        if var field = next.search, let local = localFieldValues[field.id], (field.editSequence ?? -1) < local.sequence {
            field.value = local.value
            next.search = field
        }
        func preserve(_ rows: [NativePopupRow]) -> [NativePopupRow] {
            rows.map { input in
                var row = input
                if row.kind == .textField, let local = localFieldValues[row.id], (row.editSequence ?? -1) < local.sequence { row.value = local.value }
                if let children = row.children { row.children = preserve(children) }
                return row
            }
        }
        next.rows = preserve(next.rows)
        if let rail = next.rail { next.rail = preserve(rail) }
        if let footer = next.footer { next.footer = preserve(footer) }
        return next
    }

    private func flattenIDs(_ row: NativePopupRow) -> [String] {
        [row.id] + (row.children ?? []).flatMap(flattenIDs)
    }
}
