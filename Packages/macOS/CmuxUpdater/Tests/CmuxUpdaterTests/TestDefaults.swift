import Foundation
import Darwin

/// A test's own `UserDefaults` suite that leaves no plist behind in `~/Library/Preferences`.
///
/// `UserDefaults(testSuiteName:)` with a fresh UUID name writes `~/Library/Preferences/<name>.plist`
/// on the first write, and `removePersistentDomain(forName:)` empties that file but does not
/// delete it, so every test run used to leave one file per suite (about 1,600 on one dev Mac,
/// 2026-11-08). `UserDefaults(testSuiteName:)` makes the suite as before and records its name;
/// when the test process exits, every recorded suite's domain is removed and its plist deleted.
/// `TestDefaults.remove(_:)` does the same at once, for a test that wants it gone sooner.
extension UserDefaults {
    convenience init?(testSuiteName suiteName: String) {
        TestDefaults.removeAtExit(suiteName)
        self.init(suiteName: suiteName)
    }
}

enum TestDefaults {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var names: Set<String> = []
    nonisolated(unsafe) private static var registeredExitHandler = false

    /// Records `suiteName` so its domain and plist are removed when the test process exits,
    /// and returns it, for code that takes a suite name rather than a `UserDefaults`.
    @discardableResult
    static func removeAtExit(_ suiteName: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        names.insert(suiteName)
        if !registeredExitHandler {
            registeredExitHandler = true
            atexit { TestDefaults.removeAll() }
        }
        return suiteName
    }

    /// Removes the suite's domain and deletes its plist now.
    static func remove(_ suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        CFPreferencesAppSynchronize(suiteName as CFString)
        unlink(preferencesDirectory + "/" + suiteName + ".plist")
    }

    private static func removeAll() {
        lock.lock()
        let pending = names
        names = []
        lock.unlock()
        for suiteName in pending {
            remove(suiteName)
        }
    }

    /// The real user's preferences folder, where cfprefsd writes suites, whatever `HOME` says.
    private static let preferencesDirectory: String = {
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            return String(cString: home) + "/Library/Preferences"
        }
        return NSHomeDirectory() + "/Library/Preferences"
    }()
}
