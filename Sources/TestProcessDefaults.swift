import Darwin
import Foundation
import ObjectiveC

/// The persistent preferences domain this process reads and writes through
/// `UserDefaults.standard`.
///
/// Outside app-host tests this is the app's own domain. Inside an app-host
/// test process it is that process's private domain (see
/// ``TestProcessDefaults``). Code that names the app's domain explicitly,
/// through Core Foundation or `persistentDomain(forName:)`, must use these
/// values so it sees the same domain as `UserDefaults.standard`.
enum ProcessDefaultsDomain {
    /// The domain name, or `nil` when the bundle has no identifier.
    static var name: String? {
        TestProcessDefaults.isolatedDomainName ?? Bundle.main.bundleIdentifier
    }

    /// The Core Foundation application ID for the domain.
    static var cfApplicationID: CFString {
        TestProcessDefaults.isolatedDomainName.map { $0 as CFString }
            ?? kCFPreferencesCurrentApplication
    }
}

/// Gives each app-host test process its own preferences domain.
///
/// Every app-host test process runs the same `cmux DEV` bundle, so all of them
/// share one persistent domain in the runner user's real
/// `~/Library/Preferences`. `CFFIXED_USER_HOME` does not move it: the
/// preferences daemon resolves the path from the user account, not from the
/// process environment. State one process saved (the last closed window frame,
/// the right sidebar's mode and visibility, shortcut overrides, feature flags)
/// was therefore the starting state of the next process, and of the runner
/// user's own `cmux DEV`.
///
/// Before anything reads preferences, an app-host test process replaces the
/// `+[NSUserDefaults standardUserDefaults]` implementation with one that
/// returns a suite named `<bundle id>.xctest.<pid>`. A suite's search list has
/// the argument, suite, global and registration domains but not the app's
/// domain, so the process starts from registered defaults, keeps everything
/// it writes to itself, and removes its suite when it exits. SwiftUI
/// `@AppStorage`, `NSUserDefaultsController` and package code all reach the
/// suite because they read `UserDefaults.standard`.
///
/// XCUITest-launched apps are not app-host test processes: their tests seed
/// the app's real domain before launch and must keep doing so.
enum TestProcessDefaults {
    /// The private domain of this app-host test process, or `nil` when the
    /// process uses the app's own domain.
    /// Written once in `main()` before any other thread starts.
    nonisolated(unsafe) private(set) static var isolatedDomainName: String?

    static let isolatedDomainInfix = ".xctest."

    /// Installs the private domain when this process hosts XCTest bundles.
    /// Call first in `main()`, before any code reads preferences.
    static func installIfHostingTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
#if DEBUG
        guard isolatedDomainName == nil,
              hostsTestBundles(environment: environment),
              let bundleIdentifier = Bundle.main.bundleIdentifier
        else { return }
        removeDomainsOfExitedProcesses(bundleIdentifier: bundleIdentifier)
        let domainName = isolatedDomainName(bundleIdentifier: bundleIdentifier, pid: getpid())
        guard let isolated = UserDefaults(suiteName: domainName),
              let method = class_getClassMethod(
                UserDefaults.self,
                NSSelectorFromString("standardUserDefaults")
              )
        else { return }
        // A reused PID can inherit a crashed process's leftovers.
        isolated.removePersistentDomain(forName: domainName)
        let standard: @convention(block) (AnyObject) -> UserDefaults = { _ in isolated }
        method_setImplementation(method, imp_implementationWithBlock(standard))
        isolatedDomainName = domainName
        atexit {
            guard let domainName = TestProcessDefaults.isolatedDomainName else { return }
            UserDefaults.standard.removePersistentDomain(forName: domainName)
            CFPreferencesAppSynchronize(domainName as CFString)
        }
#endif
    }

    /// Whether this process is an XCTest host: xcodebuild injects the test
    /// bundle through these variables, and the CI wrapper sets
    /// `CMUX_TEST_PROCESS` before XCTest connects. An XCUITest target app gets
    /// none of them.
    static func hostsTestBundles(environment: [String: String]) -> Bool {
        environment["CMUX_TEST_PROCESS"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCInjectBundleInto"] != nil
    }

    static func isolatedDomainName(bundleIdentifier: String, pid: pid_t) -> String {
        "\(bundleIdentifier)\(isolatedDomainInfix)\(pid)"
    }

    /// Removes private domains left by test processes that crashed before
    /// their exit handler ran. Domains of live processes are kept.
    private static func removeDomainsOfExitedProcesses(bundleIdentifier: String) {
        guard let passwd = getpwuid(getuid()), let home = passwd.pointee.pw_dir else { return }
        let preferencesURL = URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: preferencesURL.path) else {
            return
        }
        let prefix = bundleIdentifier + isolatedDomainInfix
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".plist") {
            let domainName = String(name.dropLast(".plist".count))
            guard let pid = pid_t(domainName.dropFirst(prefix.count)),
                  pid > 0,
                  kill(pid, 0) != 0,
                  errno == ESRCH
            else { continue }
            UserDefaults.standard.removePersistentDomain(forName: domainName)
            CFPreferencesAppSynchronize(domainName as CFString)
            try? FileManager.default.removeItem(at: preferencesURL.appendingPathComponent(name))
        }
    }
}
