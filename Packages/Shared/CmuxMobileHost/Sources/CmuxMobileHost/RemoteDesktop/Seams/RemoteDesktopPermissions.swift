/// Reads (never requests) the Mac's TCC grants. The phone must not make the
/// Mac raise a prompt nobody is in front of; the app's Settings owns that.
public protocol RemoteDesktopPermissions: Sendable {
    func isGranted(_ permission: RemoteDesktopPermission) async -> Bool
}
