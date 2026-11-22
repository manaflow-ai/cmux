import Darwin
import Foundation
import Testing

/// `removePersistentDomain(forName:)` alone leaves an empty `<suite>.plist` in ~/Library/Preferences;
/// `TestDefaults.remove(_:)` must leave no file, also after cfprefsd has had time to write one back.
@Suite struct TestDefaultsTests {
    private static func plistPath(_ suiteName: String) -> String {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return home + "/Library/Preferences/" + suiteName + ".plist"
    }

    @Test func removeDeletesTheSuitesPlist() async throws {
        let suiteName = "cmux.updater.test-defaults-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suiteName))
        defaults.set(true, forKey: "written")
        defaults.synchronize()

        TestDefaults.remove(suiteName)
        let path = Self.plistPath(suiteName)
        #expect(!FileManager.default.fileExists(atPath: path))
        // cfprefsd writes a file back on its own time and says nothing when it does not: look for the file
        // for the half second it had, ending the instant one appears.
        let deadline = ContinuousClock.now + .milliseconds(500)
        var writtenBack = false
        while !writtenBack, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            writtenBack = FileManager.default.fileExists(atPath: path)
        }
        #expect(!writtenBack, "cfprefsd wrote the removed suite's plist back")
    }
}
