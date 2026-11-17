@testable import CmuxNextComputerUse
import Foundation
import Testing

/// cmux Remote's supervisor ships inside the Computer Use helper, the one app macOS asks and
/// names for Accessibility and Screen Recording; the retired `cmux Remote.app` is never used.
struct ComputerUseRemoteExecutableTests {
    let app = URL(fileURLWithPath: "/Applications/cmux NIGHTLY.app")

    func supervisor(in helper: String) -> String {
        app.appending(path: "Contents/Library/\(helper)/Contents/MacOS/cmux-remote").path
    }

    @Test func theSupervisorIsFoundInTheReleaseHelperFirst() {
        let present: Set = [supervisor(in: "cmux Computer Use.app"), supervisor(in: "cmux Computer Use (dev).app")]
        let found = ComputerUseRemoteSource.executable(appURL: app) { present.contains($0) }
        #expect(found?.path == supervisor(in: "cmux Computer Use.app"))
    }

    @Test func aDevHelperCarryingTheSupervisorIsFound() {
        let present: Set = [supervisor(in: "cmux Computer Use (dev).app")]
        let found = ComputerUseRemoteSource.executable(appURL: app) { present.contains($0) }
        #expect(found?.path == supervisor(in: "cmux Computer Use (dev).app"))
    }

    @Test func noSupervisorMeansTheInAppHelperRuns() {
        // A DEV helper published before it carried the supervisor, and the retired bundle.
        let present: Set = [supervisor(in: "cmux Remote.app"), supervisor(in: "cmux Remote (dev).app")]
        #expect(ComputerUseRemoteSource.executable(appURL: app) { present.contains($0) } == nil)
    }
}
