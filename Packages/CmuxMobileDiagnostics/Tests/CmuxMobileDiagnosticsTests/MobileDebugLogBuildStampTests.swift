import Foundation
import Testing
@testable import CmuxMobileDiagnostics

/// The build stamp must come from the *injected* bundle/file manager, not from
/// hardcoded `Bundle.main` / `FileManager.default` globals.
@Suite struct MobileDebugLogBuildStampTests {
    private func makeTemporaryBundle(infoPlist: [String: Any]?) throws -> Bundle {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("debuglog-stamp-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let infoPlist {
            let data = try PropertyListSerialization.data(
                fromPropertyList: infoPlist,
                format: .xml,
                options: 0
            )
            try data.write(to: directory.appendingPathComponent("Info.plist"))
        }
        return try #require(Bundle(path: directory.path))
    }

    @Test func buildStampUsesInjectedBundleName() throws {
        let bundle = try makeTemporaryBundle(infoPlist: ["CFBundleName": "cmux DEV stamp-test"])
        let log = MobileDebugLog(sink: MobileDebugLogSink(), bundle: bundle)
        // No executable in the synthetic bundle, so the stamp is the name alone.
        #expect(log.buildStamp == "cmux DEV stamp-test")
    }

    @Test func buildStampFallsBackWhenBundleHasNoMetadata() throws {
        let bundle = try makeTemporaryBundle(infoPlist: nil)
        let log = MobileDebugLog(sink: MobileDebugLogSink(), bundle: bundle)
        #expect(log.buildStamp == "build ?")
    }
}
