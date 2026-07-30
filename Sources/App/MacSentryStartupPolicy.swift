import Foundation
import MachO

struct MacSentryStartupPolicy: Sendable {
    let telemetryEnabled: Bool
    let isRunningUnderXCTest: Bool
    let allowUnderXCTest: Bool

    init(
        telemetryEnabled: Bool,
        isRunningUnderXCTest: Bool,
        allowUnderXCTest: Bool
    ) {
        self.telemetryEnabled = telemetryEnabled
        self.isRunningUnderXCTest = isRunningUnderXCTest
        self.allowUnderXCTest = allowUnderXCTest
    }

    init(
        environment: [String: String],
        telemetryEnabled: Bool
    ) {
        self.init(
            telemetryEnabled: telemetryEnabled,
            isRunningUnderXCTest: Self.isRunningUnderXCTest(environment: environment),
            allowUnderXCTest: environment["CMUX_TEST_SENTRY_ENABLED"] == "1"
        )
    }

    var shouldStart: Bool {
        telemetryEnabled && (!isRunningUnderXCTest || allowUnderXCTest)
    }

    static func isRunningUnderXCTest(environment: [String: String]) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCTestBundlePath"] != nil { return true }
        if environment["XCTestSessionIdentifier"] != nil { return true }
        if environment["XCInjectBundle"] != nil { return true }
        if environment["XCInjectBundleInto"] != nil { return true }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true { return true }
        if environment.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) { return true }
        if hasXCTestRuntimeArtifacts() { return true }
        return false
    }

    static func containsXCTestArtifacts(
        plugInNames: [String],
        frameworkNames: [String],
        loadedImageNames: [String] = []
    ) -> Bool {
        return plugInNames.contains { $0.hasSuffix(".xctest") }
            || frameworkNames.contains("libXCTestBundleInject.dylib")
            || loadedImageNames.contains {
                ($0 as NSString).lastPathComponent == "libXCTestBundleInject.dylib"
            }
    }

    private static func hasXCTestRuntimeArtifacts() -> Bool {
        let fileManager = FileManager.default
        let plugInNames = Bundle.main.builtInPlugInsPath.flatMap {
            try? fileManager.contentsOfDirectory(atPath: $0)
        } ?? []
        let frameworkNames = Bundle.main.privateFrameworksPath.flatMap {
            try? fileManager.contentsOfDirectory(atPath: $0)
        } ?? []
        return containsXCTestArtifacts(
            plugInNames: plugInNames,
            frameworkNames: frameworkNames,
            loadedImageNames: loadedImageNames()
        )
    }

    private static func loadedImageNames() -> [String] {
        (0..<_dyld_image_count()).compactMap { imageIndex in
            _dyld_get_image_name(imageIndex).map(String.init(cString:))
        }
    }
}
