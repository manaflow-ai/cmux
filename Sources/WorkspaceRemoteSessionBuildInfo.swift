import CmuxCore
import CmuxRemoteSession
import Foundation

// The app-side conformer of the session coordinator's build-info seam:
// `Bundle.main` reads stay in the app target (the checkpoint-5b ruling), the
// package only sees the values. Reads happen per call, exactly like the
// legacy controller's direct `Bundle.main` accesses.
struct WorkspaceRemoteSessionBuildInfo: RemoteSessionBuildInfoProviding {
    func appVersion() -> String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    func embeddedDaemonManifest() -> WorkspaceRemoteDaemonManifest? {
        WorkspaceRemoteDaemonManifest(infoDictionary: Bundle.main.infoDictionary)
    }

    func executableDirectoryURL() -> URL? {
        Bundle.main.executableURL?.deletingLastPathComponent()
    }
}
