import CmuxNextWakeups
import Foundation

/// The real macOS login lock for Sleepy Mode's Lock Mac button: the supported
/// `CGSession -suspend` (back needs the account password or Touch ID), else
/// `pmset displaysleepnow`, which locks when the Mac asks for a password on wake.
struct SleepyMacLock {
    static let cgSession = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"

    /// The lock's child spawns off the main thread (a fork can take hundreds of ms); a person waits for it.
    private let launcher = ProcessLauncher(label: "com.cmuxterm.next.sleepy-lock", priority: .userBlocking)

    func lock() {
        let process = Process()
        if FileManager.default.isExecutableFile(atPath: Self.cgSession) {
            process.executableURL = URL(fileURLWithPath: Self.cgSession)
            process.arguments = ["-suspend"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
        }
        launcher.launch(process)
    }
}
