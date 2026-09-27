import Foundation
import Testing

@testable import CmuxFoundation

/// Behavior tests for the change-only `UserDefaults` writers: each no-op write
/// must post no `didChangeNotification`, and real changes still post exactly one.
@Suite struct UserDefaultsChangeOnlyWritesTests {
    @Test func dataWriteIsSilentWhenUnchanged() throws {
        try withIsolatedDefaults { defaults, counter in
            let payload = Data("geometry".utf8)
            #expect(defaults.setIfChanged(payload, forKey: "k"))
            #expect(counter.value == 1)
            #expect(!defaults.setIfChanged(payload, forKey: "k"))
            #expect(counter.value == 1)
            #expect(defaults.setIfChanged(Data("moved".utf8), forKey: "k"))
            #expect(counter.value == 2)
            #expect(defaults.data(forKey: "k") == Data("moved".utf8))
        }
    }

    @Test func boolWriteIsSilentWhenUnchanged() throws {
        try withIsolatedDefaults { defaults, counter in
            #expect(defaults.setIfChanged(true, forKey: "flag"))
            #expect(!defaults.setIfChanged(true, forKey: "flag"))
            #expect(counter.value == 1)
            #expect(defaults.setIfChanged(false, forKey: "flag"))
            #expect(counter.value == 2)
            #expect(defaults.object(forKey: "flag") as? Bool == false)
        }
    }

    @Test func removalIsSilentWhenAbsent() throws {
        try withIsolatedDefaults { defaults, counter in
            #expect(!defaults.removeObjectIfPresent(forKey: "missing"))
            #expect(counter.value == 0)
            defaults.set("v", forKey: "present")
            #expect(defaults.removeObjectIfPresent(forKey: "present"))
            #expect(counter.value == 2)
            #expect(defaults.object(forKey: "present") == nil)
        }
    }

    private func withIsolatedDefaults(
        _ body: (UserDefaults, NotificationTally) throws -> Void
    ) throws {
        let suiteName = "UserDefaultsChangeOnlyWritesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let counter = NotificationTally()
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: nil
        ) { _ in counter.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        try body(defaults, counter)
    }
}

private final class NotificationTally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
