import Foundation

/// Text acknowledgments are scoped to this presentation and bounded by its live fields.
struct NativePopupInputState {
    private var pending: [String: (sequence: Int, value: String)] = [:]
    private var sequence = 0
    private(set) var lastSequence: Int?

    mutating func record(id: String, value: String, model: NativePopupModel?) {
        guard let model, let acknowledged = fields(in: model)[id] else { lastSequence = nil; return }
        sequence = max(sequence, acknowledged) + 1
        pending[id] = (sequence, value)
        lastSequence = sequence
    }

    mutating func preservingLocalEdits(in incoming: NativePopupModel) -> NativePopupModel {
        let active = fields(in: incoming)
        pending = pending.filter { id, local in active[id].map { $0 < local.sequence } ?? false }
        var next = incoming
        if var field = next.search, let local = pending[field.id] {
            field.value = local.value
            next.search = field
        }
        func preserve(_ rows: [NativePopupRow]) -> [NativePopupRow] {
            rows.map { input in
                var row = input
                if row.kind == .textField, let local = pending[row.id] { row.value = local.value }
                if let children = row.children { row.children = preserve(children) }
                return row
            }
        }
        next.rows = preserve(next.rows)
        if let rail = next.rail { next.rail = preserve(rail) }
        if let footer = next.footer { next.footer = preserve(footer) }
        return next
    }

    private func fields(in model: NativePopupModel) -> [String: Int] {
        var result: [String: Int] = [:]
        if let search = model.search, search.disabled != true, let acknowledgment = search.editSequence {
            result[search.id] = acknowledgment
        }
        func visit(_ rows: [NativePopupRow]) {
            for row in rows where row.disabled != true {
                if row.kind == .textField, let acknowledgment = row.editSequence { result[row.id] = acknowledgment }
                if let children = row.children { visit(children) }
            }
        }
        visit((model.rail ?? []) + model.rows + (model.footer ?? []))
        return result
    }
}
