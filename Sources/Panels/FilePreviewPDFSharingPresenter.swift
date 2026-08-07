import AppKit

/// Owns the sharing picker presented by one PDF preview container.
@MainActor
final class FilePreviewPDFSharingPresenter: NSObject {
    typealias PickerFactory = ([Any]) -> NSSharingServicePicker
    typealias MenuPresenter = (NSMenu, NSView) -> Void
    typealias EventTypeProvider = (NSView) -> NSEvent.EventType?

    private let currentEventType: EventTypeProvider
    private let presentMenu: MenuPresenter
    private let makePicker: PickerFactory
    private var activePicker: NSSharingServicePicker?
    private var activeMenu: NSMenu?

    init(
        currentEventType: @escaping EventTypeProvider = { anchorView in
            guard let event = NSApp.currentEvent,
                  event.window === anchorView.window else { return nil }
            return event.type
        },
        presentMenu: @escaping MenuPresenter = { menu, anchorView in
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: anchorView.bounds.midX, y: anchorView.bounds.minY),
                in: anchorView
            )
        },
        makePicker: @escaping PickerFactory = { NSSharingServicePicker(items: $0) }
    ) {
        self.currentEventType = currentEventType
        self.presentMenu = presentMenu
        self.makePicker = makePicker
    }

    /// Presents sharing services for the current PDF from its visible chrome control.
    func present(fileURL: URL, from anchorView: NSView) {
        close()

        let picker = makePicker([fileURL])
        picker.delegate = self
        activePicker = picker
        if currentEventType(anchorView) == .leftMouseDown {
            picker.show(
                relativeTo: anchorView.bounds,
                of: anchorView,
                preferredEdge: .maxY
            )
        } else {
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
