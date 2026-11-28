public import Foundation
import MessagesLabHome

/// The app's switch for MessagesLab's flight recorder in the Home transcript
/// (`HomeFlightRecorder`, `HomeTunables`): the policy is read live, so a
/// Debug Settings toggle applies at the next send.
public struct HomeFlightRecording {
    public init() {}
    /// `available`: this build offers developer tools (`DevTools.isEnabled`,
    /// DEV and NIGHTLY); Release and RC pass false and never record.
    /// `logFolder`: the folder under ~/Library/Logs (the app's name).
    public static func install(available: Bool, logFolder: String) {
        HomeFlightRecorder.logFolder = logFolder
        HomeFlightRecorder.isEnabled = { available && HomeTunables.flightRecorder.value }
        HomeFlightRecorder.capturesWindow = { available && HomeTunables.flightRecorder.value && HomeTunables.flightRecorderCaptures.value }
    }

    /// "Save Last 10 Seconds": the dump folder, or nil when the recorder is
    /// off or no Home transcript is attached.
    @discardableResult
    public static func saveLastSeconds() -> String? { HomeFlightRecorder.saveLastSeconds() }
}
