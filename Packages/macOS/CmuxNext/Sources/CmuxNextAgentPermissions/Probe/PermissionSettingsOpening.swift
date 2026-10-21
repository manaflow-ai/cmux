/// Takes the person to where a grant is given, only after they pressed
/// Continue on the card: the System Settings list for kinds with a list
/// (``PermissionKind/usesDragHelper``), else the one macOS prompt
/// (camera, microphone, automation of `target`).
@MainActor
public protocol PermissionSettingsOpening: AnyObject {
    /// Opens the list for `kind` (or asks macOS once).
    func open(_ kind: PermissionKind, target: String?)
}
