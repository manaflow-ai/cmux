import AppKit
public import CmuxMobileHost

/// The Mac's general pasteboard for remote desktop: read only when the phone
/// asks, written right before a paste the phone started.
public struct GeneralRemoteDesktopPasteboard: RemoteDesktopPasteboard {
    public init() {}

    public func readText() async -> String? {
        await MainActor.run { NSPasteboard.general.string(forType: .string) }
    }

    public func writeText(_ text: String) async {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
