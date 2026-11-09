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
        #expect(!FileManager.default.fileExists(atPath: Self.plistPath(suiteName)))
        try await Task.sleep(for: .milliseconds(500))
        #expect(!FileManager.default.fileExists(atPath: Self.plistPath(suiteName)))
    }
}
