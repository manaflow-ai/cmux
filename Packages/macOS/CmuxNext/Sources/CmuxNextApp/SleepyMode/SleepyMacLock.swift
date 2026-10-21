import Foundation

/// The real macOS login lock for Sleepy Mode's Lock Mac button: the supported
/// `CGSession -suspend` (back needs the account password or Touch ID), else
/// `pmset displaysleepnow`, which locks when the Mac asks for a password on wake.
struct SleepyMacLock {
    static let cgSession = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"

    func lock() {
        let process = Process()
        if FileManager.default.isExecutableFile(atPath: Self.cgSession) {
            process.executableURL = URL(fileURLWithPath: Self.cgSession)
            process.arguments = ["-suspend"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
        }
        try? process.run()
    }
}
