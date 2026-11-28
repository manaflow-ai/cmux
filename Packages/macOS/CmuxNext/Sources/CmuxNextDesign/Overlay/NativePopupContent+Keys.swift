import AppKit

extension NativePopupContent {
    /// The row the highlight starts on: the list's first, or in columns the first of the first
    /// column that is not a rail (the models, never a harness tab).
    var defaultRowID: String? {
        if model?.hasColumns == true { return firstListColumnRowID }
        return listRows.first?.id
    }

    var railIDs: Set<String> { Set((model?.rail ?? []).map(\.id)) }

    func handleKey(_ key: UInt16) -> Bool {
        let enabled = listRows
        if key == 53 { dismiss(); return true }
        if model?.hasColumns == true, let handled = handleColumnKey(key) { return handled }
        if key == 123 || key == 124, model?.rail?.isEmpty == false {
            // Right opens a highlighted row's side dropdown; otherwise Left and Right step the rail,
            // and the page picks the tab (its tabs are not rows: Up and Down stay in the list).
            if key == 124, let row = listRow(selected), row.opensChildren, let view = rowView(id: row.id) {
                openSubmenu(row, view)
                return true
            }
            emit(.navigate, nil, key == 124 ? "next" : "previous")
            return true
        }
        if key == 125 || key == 126 {
            guard !enabled.isEmpty else { return true }
            let index = selected.flatMap { listIndex[$0] } ?? (key == 125 ? -1 : 0)
            selected = enabled[(index + (key == 125 ? 1 : -1) + enabled.count) % enabled.count].id
            selectionReason = "keyboard"
            paintSelection()
            if window?.firstResponder === self, let selected, let view = rowView(id: selected) as? NativePopupSliderView {
                window?.makeFirstResponder(view.slider)
            }
            emit(.highlight, selected, nil)
            return true
        }
        if [36, 76, 49, 124].contains(key), let row = selectableRow(selected), let view = rowView(id: row.id) {
            if key == 124, row.opensChildren { openSubmenu(row, view); return true }
            if key != 124 { activate(row, view: view); return true }
        }
        return false
    }
}
