import AppKit

extension NativePopupContent {
    func owns(_ view: NSView?) -> Bool {
        isPresentationActive && view?.isDescendant(of: self) == true
    }

    func invalidatePresentation() {
        isPresentationActive = false
        presentationIdentity += 1
        pendingCompositionModel = nil
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
        guard structure(next.rows) == structure(model.rows), structure(next.rail) == structure(model.rail),
              structure(next.footer) == structure(model.footer) else { return false }
        let rows = (next.rail ?? []) + next.rows + (next.footer ?? [])
        for row in rows where row.kind == .slider {
            if let view = rowView(id: row.id) as? NativePopupSliderView { view.update(row: row) }
            else if let slider = editableControls[row.id] as? NativePopupTrackingSlider, !slider.isInteracting {
                slider.doubleValue = Double(row.value ?? "") ?? row.minimum ?? 0
            }
        }
        rowViews = rowViews.map { current in (rows.first { $0.id == current.0.id } ?? current.0, current.1) }
        return true
    }
}
