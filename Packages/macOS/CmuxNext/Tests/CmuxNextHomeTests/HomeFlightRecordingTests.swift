import CmuxNextDesign
@testable import CmuxNextHome
import MessagesLabHome
import Testing

/// The Home flight recorder is an opt-in in every build until MessagesLab's
/// recorder costs at most 0.3 ms a frame (it cost more main-thread time than
/// a send in DEV): off by default even in a Debug compile, a build without
/// developer tools never records, and window captures need the recorder on.
@MainActor @Suite(.serialized) struct HomeFlightRecordingTests {
    @Test func aDebugBuildDoesNotRecordByDefault() {
        HomeFlightRecording.install(available: true, logFolder: "cmux DEV test")
        defer { HomeFlightRecording.install(available: false, logFolder: "cmux") }
        #expect(!HomeTunables.flightRecorder.defaultValue)
        #expect(!HomeTunables.flightRecorderCaptures.defaultValue)
        #expect(HomeFlightRecorder.logFolder == "cmux DEV test")
    }

    @Test func aBuildWithoutDeveloperToolsNeverRecords() {
        HomeFlightRecording.install(available: false, logFolder: "cmux")
        #expect(!HomeFlightRecorder.isEnabled())
        #expect(!HomeFlightRecorder.capturesWindow())
        #expect(HomeFlightRecording.saveLastSeconds() == nil)
    }
}
