public import AppKit
public import CmuxFoundation

/// `@objc` target for file-external-open menu items.
///
/// Reads the ``FileExternalOpenMenuActionPayload`` back off the clicked
/// `NSMenuItem` and performs the open/reveal through an injected
/// ``FileExternalOpenAction`` (defaulting to the shared production action).
///
/// `NSMenuItem.target` is a weak reference, so whatever wires items to this
/// target (``FileExternalOpenMenuBuilder``) must keep it alive for the menu's
/// interactive lifetime.
public final class FileExternalOpenMenuActionTarget: NSObject {
    private let action: FileExternalOpenAction

    /// Creates a target performing opens through `action`.
    /// - Parameter action: The open/reveal action; defaults to ``FileExternalOpenAction/live``.
    public init(action: FileExternalOpenAction = .live) {
        self.action = action
    }

    /// Performs the action carried by the chosen menu item's payload.
    @MainActor
    @objc public func open(_ item: NSMenuItem) {
        guard let payload = item.representedObject as? FileExternalOpenMenuActionPayload else {
            return
        }
        switch payload.action {
        case .open(let applicationURL):
            guard let applicationURL else {
                action.openDefault(fileURL: payload.fileURL)
                return
            }
            action.open(fileURL: payload.fileURL, applicationURL: applicationURL)
        case .revealInFinder:
            action.revealInFinder(fileURL: payload.fileURL)
        }
    }
}
