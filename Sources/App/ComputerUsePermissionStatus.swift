import Foundation

/// The two macOS grants read from the standalone Computer Use daemon.
struct ComputerUsePermissionStatus: Equatable, Sendable {
    var accessibility: Bool
    var screenRecording: Bool
    var isKnown: Bool

    init(accessibility: Bool, screenRecording: Bool, isKnown: Bool) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.isKnown = isKnown
    }

    init?(structuredContent: [String: Any]) {
        guard
            let accessibility = structuredContent["accessibility"] as? Bool,
            let screenRecording = structuredContent["screen_recording"] as? Bool
        else {
            return nil
        }
        self.init(
            accessibility: accessibility,
            screenRecording: screenRecording,
            isKnown: true
        )
    }

    func applyingProbeResult(
        _ latest: ComputerUsePermissionStatus?
    ) -> ComputerUsePermissionStatus {
        guard let latest else {
            var unavailable = self
            unavailable.isKnown = false
            return unavailable
        }
        return latest
    }

    static let unknown = ComputerUsePermissionStatus(
        accessibility: false,
        screenRecording: false,
        isKnown: false
    )
}
