import AppKit

extension NativePopupContent {
    func owns(_ view: NSView?) -> Bool {
        isPresentationActive && view?.isDescendant(of: self) == true
    }

    func invalidatePresentation() {
        isPresentationActive = false
        presentationIdentity += 1
        pendingCompositionModel = nil
        pendingInteractionModel = nil
        for field in fields.values { field.delegate = nil; _ = field.abortEditing() }
    }

    /// Value echoes must not replace the control that AppKit is currently tracking.
    func retainSliders(updating next: NativePopupModel) -> Bool {
        guard let model else { return false }
        func structure(_ rows: [NativePopupRow]?) -> [NativePopupRow]? {
            rows?.map { input in
                var row = input
                if row.kind == .slider { row.value = nil; row.slider?.selectedValue = nil }
                return row
            }
        }
        // Only the rows' structure counts: the revision and other fields change on every echo.
        let incoming = next.mappingRows { structure($0) ?? [] }, shown = model.mappingRows { structure($0) ?? [] }
        guard incoming.rows == shown.rows, incoming.rail == shown.rail, incoming.footer == shown.footer,
              incoming.columns == shown.columns, incoming.searchAccessory == shown.searchAccessory else { return false }
        let rows = next.allRows
        for row in rows where row.kind == .slider {
            if let view = mounted[row.id]?.view as? NativePopupSliderView { view.update(row: row) }
            else if let slider = editableControls[row.id] as? NativePopupTrackingSlider, !slider.isInteracting {
                slider.doubleValue = Double(row.value ?? "") ?? row.minimum ?? 0
            }
        }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rowViews = rowViews.map { (byID[$0.0.id] ?? $0.0, $0.1) }
        shownRows = shownRows.map { byID[$0.id] ?? $0 }
        listRows = listRows.map { byID[$0.id] ?? $0 }
        columnListRows = columnListRows.map { $0.map { byID[$0.id] ?? $0 } }
        // An undrawn row draws the echoed value when it comes into view.
        for window in rowWindows { window.rows = window.rows.map { byID[$0.id] ?? $0 } }
        return true
    }

    /// AppKit is tracking one of this popup's sliders (a drag, or a key on it).
    var isTrackingSlider: Bool {
        editableControls.values.contains { ($0 as? NativePopupTrackingSlider)?.isInteracting == true }
    }

    /// The update a slider drag deferred, once the drag has ended.
    func applyPendingInteraction() {
        guard isPresentationActive, !isTrackingSlider, let pending = pendingInteractionModel else { return }
        pendingInteractionModel = nil
        update(pending)
    }
}
