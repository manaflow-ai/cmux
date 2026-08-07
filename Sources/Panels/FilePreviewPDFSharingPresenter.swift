import AppKit

/// Owns the sharing picker presented by one PDF preview container.
@MainActor
final class FilePreviewPDFSharingPresenter: NSObject {
    typealias PickerFactory = ([Any]) -> NSSharingServicePicker

    private let makePicker: PickerFactory
    private var activePicker: NSSharingServicePicker?

    init(makePicker: @escaping PickerFactory = { NSSharingServicePicker(items: $0) }) {
        self.makePicker = makePicker
    }

    /// Presents sharing services for the current PDF from its visible chrome control.
    func present(fileURL: URL, from anchorView: NSView) {
        close()

        let picker = makePicker([fileURL])
        picker.delegate = self
        activePicker = picker
        picker.show(
            relativeTo: anchorView.bounds,
            of: anchorView,
            preferredEdge: .maxY
        )
    }

    /// Dismisses and releases the active picker, if any.
    func close() {
        guard let activePicker else { return }
        self.activePicker = nil
        activePicker.delegate = nil
        activePicker.close()
    }
}

extension FilePreviewPDFSharingPresenter: NSSharingServicePickerDelegate {
    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        guard sharingServicePicker === activePicker else { return }
        sharingServicePicker.delegate = nil
        activePicker = nil
    }
}
