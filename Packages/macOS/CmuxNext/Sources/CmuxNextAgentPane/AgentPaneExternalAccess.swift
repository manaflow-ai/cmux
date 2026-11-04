import AppKit
import CmuxNextCompat
public import Foundation

/// The two macOS settings destinations an OS-blocked read may need. This value is decoded from a
/// closed allow-list; the daemon remains the authority for detecting the block and retrying reads.
public nonisolated enum AgentPaneExternalAccessKind: String, Equatable, Sendable {
    case filesAndFolders = "files_and_folders"
    case fullDiskAccess = "full_disk_access"

    var settingsAnchor: String {
        switch self {
        case .filesAndFolders: "Privacy_FilesAndFolders"
        case .fullDiskAccess: "Privacy_AllFiles"
        }
    }

    public var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")
    }
}

/// Opens Privacy & Security only after a real person gesture. A Cloud chat's block belongs to its
/// remote machine, so this Mac never opens local settings for it.
@MainActor
public struct AgentPaneExternalAccess {
    public init() {}

    public func open(
        _ kind: AgentPaneExternalAccessKind,
        remoteChat: Bool,
        gestures: AgentPaneUserGestures,
        open: ((URL) -> Void)? = nil,
    ) -> [String: Any] {
        guard !remoteChat else {
            return AgentPaneReply.failure(code: RemoteAcpmuxWire.unsupported, message: RemoteAcpmuxWire.unsupported)
        }
        guard gestures.consume(), let url = kind.settingsURL else { return AgentPaneModel.transportFailure(.gestureRequired) }
        if let open { open(url) } else { NSWorkspace.shared.openInBackground(url) }
        return AgentPaneReply.success(["opened": true])
    }
}
