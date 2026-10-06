import CmuxNextDaemon
import Foundation

extension AppServices {
    /// The state roots whose stores rollback must still read: this tag's
    /// app daemon and the Chief conversation owner's.
    var daemonStateDirectories: [URL?] {
        let tag = environment.tag
        return [tag.map(DaemonLauncher.tagStateDirectory(tag:)), ChiefHome.resolve(tag: tag).daemonStateDirectory]
    }
}
