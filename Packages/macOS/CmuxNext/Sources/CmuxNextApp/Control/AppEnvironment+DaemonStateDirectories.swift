import CmuxNextDaemon
import Foundation

extension AppEnvironment {
    /// The state roots whose stores rollback must still read: this tag's
    /// app daemon and the Chief conversation owner's.
    var daemonStateDirectories: [URL?] {
        [tag.map(DaemonLauncher.tagStateDirectory(tag:)), ChiefHome.resolve(tag: tag).daemonStateDirectory]
    }
}
