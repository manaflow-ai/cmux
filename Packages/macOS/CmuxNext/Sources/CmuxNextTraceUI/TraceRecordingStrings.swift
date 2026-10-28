import Foundation

/// The trace recording indicator's text (`TraceRecording.xcstrings`).
enum TraceRecordingStrings {
    static var title: String {
        String(localized: "traceRecording.title", defaultValue: "Recording trace", table: "TraceRecording", bundle: .module)
    }

    static var stop: String {
        String(localized: "traceRecording.stop", defaultValue: "Stop", table: "TraceRecording", bundle: .module)
    }

    static var stopping: String {
        String(localized: "traceRecording.stopping", defaultValue: "Stopping…", table: "TraceRecording", bundle: .module)
    }

    /// The Stop button's tooltip and accessibility label.
    static var stopHelp: String {
        String(localized: "traceRecording.stopHelp", defaultValue: "Stop the trace recording", table: "TraceRecording", bundle: .module)
    }
}
