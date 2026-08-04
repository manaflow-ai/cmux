import Foundation

/// Distinguishes product launches from the two XCTest process shapes.
///
/// UI tests launch the production app target and need its normal window bootstrap.
/// App-host unit tests instead embed an `.xctest` plug-in in the app and need only
/// headless services until an individual test explicitly creates a window.
enum MacAppLaunchMode: Equatable, Sendable {
    case normal
    case uiTest
    case unitTestHost

    init(
        environment: [String: String],
        hasEmbeddedUnitTestBundle: Bool
    ) {
        // UI-test markers take precedence because those runs may also expose
        // generic XCTest injection keys while still requiring a real app window.
        if environment.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) {
            self = .uiTest
        } else if environment["CMUX_TEST_PROCESS"] == "1"
            || hasEmbeddedUnitTestBundle {
            self = .unitTestHost
        } else {
            self = .normal
        }
    }

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> Self {
        let hasEmbeddedUnitTestBundle = bundle.builtInPlugInsURL.map { plugInsURL in
            fileManager.fileExists(
                atPath: plugInsURL
                    .appendingPathComponent("cmuxTests.xctest", isDirectory: true)
                    .path
            )
        } ?? false
        return Self(
            environment: environment,
            hasEmbeddedUnitTestBundle: hasEmbeddedUnitTestBundle
        )
    }

    var shouldAutomaticallyCreateMainWindow: Bool {
        switch self {
        case .normal, .uiTest:
            true
        case .unitTestHost:
            false
        }
    }

    var isTestLaunch: Bool {
        self != .normal
    }
}
