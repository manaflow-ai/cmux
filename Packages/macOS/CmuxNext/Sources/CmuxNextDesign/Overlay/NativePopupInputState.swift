import Foundation

/// Text acknowledgments are scoped to this presentation and bounded by its live fields.
struct NativePopupInputState {
    private var pending: [String: (sequence: Int, value: String, identity: [String])] = [:]
    private var sequence = 0
    private(set) var lastSequence: Int?

    mutating func record(id: String, value: String, model: NativePopupModel?, allocate: ((Int) -> Int)? = nil) {
        guard let model, let field = fields(in: model)[id] else { lastSequence = nil; return }
        let floor = max(sequence, field.acknowledgment)
        sequence = allocate?(floor) ?? (floor + 1)
        pending[id] = (sequence, value, field.identity)
        lastSequence = sequence
    }

    mutating func preservingLocalEdits(in incoming: NativePopupModel) -> NativePopupModel {
        let active = fields(in: incoming)
        pending = pending.filter { id, local in
            active[id].map { $0.identity == local.identity && $0.acknowledgment < local.sequence } ?? false
        }
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

    private func fields(in model: NativePopupModel) -> [String: (acknowledgment: Int, identity: [String])] {
        var result: [String: (acknowledgment: Int, identity: [String])] = [:]
        if let search = model.search, search.disabled != true, let acknowledgment = search.editSequence {
            result[search.id] = (acknowledgment, ["search"])
        }
        func visit(_ rows: [NativePopupRow], ancestors: [String] = []) {
            for row in rows where row.disabled != true {
                if row.kind == .textField, let acknowledgment = row.editSequence {
                    result[row.id] = (acknowledgment, ["row"] + ancestors)
                }
                if let children = row.children { visit(children, ancestors: ancestors + [row.id]) }
            }
        }
        visit((model.rail ?? []) + model.rows + (model.footer ?? []))
        return result
    }
}
