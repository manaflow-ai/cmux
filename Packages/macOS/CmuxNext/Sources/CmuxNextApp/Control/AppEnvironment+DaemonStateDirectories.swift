import CmuxNextDaemon
import CmuxNextHomeEngine
import Foundation

extension AppEnvironment {
    /// The state roots whose stores rollback must still read: this build's
    /// app daemon and the Chief conversation owner's.
    var daemonStateDirectories: [URL?] {
        [daemonStateDirectory, ChiefHome.resolve(tag: tag).daemonStateDirectory]
    }

    /// This app's daemon session and state directory (nil: cmux-tui's
    /// default root, release): the app's own build (`LaunchIdentity.build`,
    /// `DaemonLauncher.appNames`), never a DEBUG test override.
    var daemonSession: String { DaemonLauncher.appNames(build: launch.build).session }
    var daemonStateDirectory: URL? { DaemonLauncher.appNames(build: launch.build).stateDirectory }
}
