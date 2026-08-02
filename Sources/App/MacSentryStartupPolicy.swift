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

    static func isRunningUnderXCTest(
        environment: [String: String],
        loadedImageNames: [String]? = nil,
        embeddedPlugInURLs: [URL]? = nil
    ) -> Bool {
        if environment["CMUX_XCTEST_APP_HOST"] == "1" { return true }
        if environment["CMUX_TEST_PROCESS"] == "1" { return true }
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCTestBundlePath"] != nil { return true }
        if environment["XCTestSessionIdentifier"] != nil { return true }
        if environment["XCInjectBundle"] != nil { return true }
        if environment["XCInjectBundleInto"] != nil { return true }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true { return true }
        if environment.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) { return true }
        if containsEmbeddedXCTestBundle(
            embeddedPlugInURLs ?? builtInPlugInURLs()
        ) { return true }
        if containsLoadedXCTestInjectionImage(
            loadedImageNames ?? Self.loadedImageNames()
        ) { return true }
        return false
    }

    static func containsEmbeddedXCTestBundle(_ plugInURLs: [URL]) -> Bool {
        plugInURLs.contains {
            $0.pathExtension.caseInsensitiveCompare("xctest") == .orderedSame
        }
    }

    static func containsLoadedXCTestInjectionImage(
        _ loadedImageNames: [String]
    ) -> Bool {
        loadedImageNames.contains {
            ($0 as NSString).lastPathComponent == "libXCTestBundleInject.dylib"
        }
    }

    private static func builtInPlugInURLs() -> [URL] {
        guard let directory = Bundle.main.builtInPlugInsURL else { return [] }
        return (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
    }

    private static func loadedImageNames() -> [String] {
        (0..<_dyld_image_count()).compactMap { imageIndex in
            _dyld_get_image_name(imageIndex).map(String.init(cString:))
        }
    }
}
