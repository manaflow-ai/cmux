import AppKit

/// Owns the sharing picker presented by one PDF preview container.
@MainActor
final class FilePreviewPDFSharingPresenter: NSObject {
    typealias PickerFactory = @MainActor ([Any]) -> NSSharingServicePicker
    typealias MenuPresenter = @MainActor (NSMenu, NSView) -> Void

    private let presentMenu: MenuPresenter
    private let makePicker: PickerFactory
    private var activePicker: NSSharingServicePicker?
    private var activeMenu: NSMenu?

    init(
        presentMenu: @escaping MenuPresenter = { menu, anchorView in
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: anchorView.bounds.midX, y: anchorView.bounds.minY),
                in: anchorView
            )
        },
        makePicker: @escaping PickerFactory = { NSSharingServicePicker(items: $0) }
    ) {
        self.presentMenu = presentMenu
        self.makePicker = makePicker
    }

    /// Presents sharing services for the current PDF from its visible chrome control.
    func present(fileURL: URL, from anchorView: NSView, activation: FilePreviewPDFShareActivation) {
        close()

        let picker = makePicker([fileURL])
        picker.delegate = self
        activePicker = picker
        switch activation {
        case .pointerDown:
            picker.show(
                relativeTo: anchorView.bounds,
                of: anchorView,
                preferredEdge: .maxY
            )
        case .nonPointer:
            let menu = NSMenu()
            menu.addItem(picker.standardShareMenuItem)
            activeMenu = menu
            presentMenu(menu, anchorView)
            if activeMenu === menu {
                activeMenu = nil
            }
        }
    }

    /// Dismisses and releases the active picker, if any.
    func close() {
        let activeMenu = activeMenu
        self.activeMenu = nil
        activeMenu?.cancelTracking()

        guard let activePicker else { return }
        self.activePicker = nil
        activePicker.delegate = nil
        activePicker.close()
    }

    private func pickerDidChooseService(_ sharingServicePicker: NSSharingServicePicker) {
        guard sharingServicePicker === activePicker else { return }
        sharingServicePicker.delegate = nil
        activePicker = nil
    }
}

#if compiler(>=6.2)
extension FilePreviewPDFSharingPresenter: @MainActor NSSharingServicePickerDelegate {
    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        pickerDidChooseService(sharingServicePicker)
    }
}
#else
extension FilePreviewPDFSharingPresenter: NSSharingServicePickerDelegate {
    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        pickerDidChooseService(sharingServicePicker)
    }
}
#endif
