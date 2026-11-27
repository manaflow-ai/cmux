import Foundation

extension AppDelegate {
    func isRunningUnderXCTest(_ env: [String: String]) -> Bool {
        // The CI wrapper uses xcodebuild's TEST_RUNNER_ forwarding so its marker
        // exists before XCTest connects. Standard XCTest keys cover other paths.
        MacSentryStartupPolicy.isRunningUnderXCTest(environment: env)
    }

}
