import CmuxNextDesign
@testable import CmuxNextHome
import MessagesLabHome
import Testing

/// The Home flight recorder follows the build: DEV records by default (this
/// test process is a Debug compile), a build without developer tools never
/// records, and window captures need the recorder on as well.
@MainActor @Suite(.serialized) struct HomeFlightRecordingTests {
    @Test func aDebugBuildRecordsByDefaultWithCaptures() {
        HomeFlightRecording.install(available: true, logFolder: "cmux DEV test")
        defer { HomeFlightRecording.install(available: false, logFolder: "cmux") }
        #expect(HomeTunables.flightRecorder.defaultValue)
        #expect(HomeFlightRecorder.isEnabled())
        #expect(HomeFlightRecorder.capturesWindow())
        #expect(HomeFlightRecorder.logFolder == "cmux DEV test")
    }

    @Test func aBuildWithoutDeveloperToolsNeverRecords() {
        HomeFlightRecording.install(available: false, logFolder: "cmux")
        #expect(!HomeFlightRecorder.isEnabled())
        #expect(!HomeFlightRecorder.capturesWindow())
        #expect(HomeFlightRecording.saveLastSeconds() == nil)
    }
}
