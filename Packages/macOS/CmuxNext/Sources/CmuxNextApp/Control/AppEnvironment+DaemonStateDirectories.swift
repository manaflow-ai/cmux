import CmuxNextDaemon
import CmuxNextHomeEngine
import Foundation

extension AppEnvironment {
    /// The state roots whose stores rollback must still read: this tag's or
    /// channel's app daemon and the Chief conversation owner's.
    var daemonStateDirectories: [URL?] {
        [daemonTag.map { DaemonLauncher.tagStateDirectory(tag: $0) }, ChiefHome.resolve(tag: tag).daemonStateDirectory]
    }

    /// The tag of this app's daemon session and state: the build's tag, else
    /// its channel (`DaemonLauncher.daemonTag`), nil for release.
    var daemonTag: String? { DaemonLauncher.daemonTag(tag: launch.tag, bundleID: launch.bundleID) }
}
