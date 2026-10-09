/// The Mac pasteboard as remote desktop uses it: read only on an explicit
/// phone request, written only right before a paste the phone started. The
/// app supplies the NSPasteboard implementation (this package has no AppKit).
public protocol RemoteDesktopPasteboard: Sendable {
    func readText() async -> String?
    func writeText(_ text: String) async
}
