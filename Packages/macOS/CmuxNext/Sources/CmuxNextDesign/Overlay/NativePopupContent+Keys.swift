import AppKit

extension NativePopupContent {
    /// The list's rows: Up, Down, digits and typeahead move among these, never along the rail.
    var enabledRows: [(NativePopupRow, NSView)] {
        let rail = railIDs
        return rowViews.filter { !$0.0.isNoninteractive && $0.0.disabled != true && !rail.contains($0.0.id) }
    }

    /// The rail's tabs a click or Return (a highlighted Add harness) activates.
    var enabledRailRows: [(NativePopupRow, NSView)] {
        let rail = railIDs
        return rowViews.filter { $0.0.disabled != true && rail.contains($0.0.id) }
    }

    var railIDs: Set<String> { Set((model?.rail ?? []).map(\.id)) }

    func handleKey(_ key: UInt16) -> Bool {
        let enabled = enabledRows
        if key == 53 { dismiss(); return true }
        if key == 123 || key == 124, model?.rail?.isEmpty == false {
            // Right opens a highlighted row's side dropdown; otherwise Left and Right step the rail,
            // and the page picks the tab (its tabs are not rows: Up and Down stay in the list).
            if key == 124, let (row, view) = enabled.first(where: { $0.0.id == selected }), row.opensChildren {
                openSubmenu(row, view)
                return true
            }
            emit(.navigate, nil, key == 124 ? "next" : "previous")
            return true
        }
        if key == 125 || key == 126 {
            guard !enabled.isEmpty else { return true }
            let index = enabled.firstIndex(where: { $0.0.id == selected }) ?? (key == 125 ? -1 : 0)
            selected = enabled[(index + (key == 125 ? 1 : -1) + enabled.count) % enabled.count].0.id
            selectionReason = "keyboard"
            paintSelection()
            if window?.firstResponder === self, let view = enabled.first(where: { $0.0.id == selected })?.1 as? NativePopupSliderView {
                window?.makeFirstResponder(view.slider)
            }
            emit(.highlight, selected, nil)
            return true
        }
        if [36, 76, 49, 124].contains(key), let (row, view) = (enabled + enabledRailRows).first(where: { $0.0.id == selected }) {
            if key == 124, row.opensChildren { openSubmenu(row, view); return true }
            if key != 124 { activate(row, view: view); return true }
        }
        return false
    }
}
