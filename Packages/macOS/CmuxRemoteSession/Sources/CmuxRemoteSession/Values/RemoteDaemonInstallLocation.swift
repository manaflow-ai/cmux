internal import Foundation

/// Where the versioned cmuxd-remote binary lives on the remote host, both
/// relative to `$HOME` and as the absolute install path. Lifted one-for-one
/// from the legacy controller's nested type.
struct RemoteDaemonInstallLocation {
    let relativePath: String
    let absolutePath: String

    var directory: String {
        (absolutePath as NSString).deletingLastPathComponent
    }
}
