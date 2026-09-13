import AppKit
import Bonsplit
import UniformTypeIdentifiers

/// Drag payload for reordering the mode bar's tabs in place. Same shape as
/// `SidebarTabDragPayload`: an in-process custom UTI (declared in
/// `Resources/Info.plist` under `UTExportedTypeDeclarations`) carrying the
/// dragged mode's raw value.
enum RightSidebarModeDragPayload {
    static let typeIdentifier = "com.cmux.right-sidebar-mode-reorder"
    static let dropContentType = UTType(exportedAs: typeIdentifier)

    @MainActor
    static func provider(for mode: RightSidebarMode, registry: TabDragTransferRegistry? = nil) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(mode.rawValue.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: typeIdentifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        if let registry = registry ?? AppDelegate.shared?.tabDragTransferRegistry {
            if let registration = RightSidebarToolDragPayload(mode: mode).register(with: registry),
               let capability = registration.pasteboardItem.string(forType: TabDragTransferRegistry.pasteboardType) {
                provider.registerDataRepresentation(
                    forTypeIdentifier: TabDragTransferRegistry.pasteboardType.rawValue,
                    visibility: .ownProcess
                ) { completion in
                    withExtendedLifetime(registration) { completion(Data(capability.utf8), nil) }
                    return nil
                }
            }
        }
        return provider
    }
}

