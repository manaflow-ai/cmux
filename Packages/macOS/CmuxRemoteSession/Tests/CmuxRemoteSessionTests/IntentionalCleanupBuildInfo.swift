import CmuxCore
import CmuxRemoteWorkspace
import Foundation
@testable import CmuxRemoteSession

struct IntentionalCleanupBuildInfo: RemoteSessionBuildInfoProviding {
    func appVersion() -> String? { nil }
    func embeddedDaemonManifest() -> WorkspaceRemoteDaemonManifest? { nil }
    func executableDirectoryURL() -> URL? { nil }
}
