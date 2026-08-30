import Foundation

/// The two macOS grants read from the standalone Computer Use daemon.
struct ComputerUsePermissionStatus: Equatable, Sendable {
    var accessibility: Bool
    var screenRecording: Bool
    var isKnown: Bool
    /// TCC attribution reported by the helper, when available.
    var sourceAttribution: String?

    private static let helperAttributions: Set<String> = [
        "helper-daemon",
        "driver-daemon",
    ]

    init(
        accessibility: Bool,
        screenRecording: Bool,
        isKnown: Bool,
        sourceAttribution: String? = nil
    ) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.isKnown = isKnown
        self.sourceAttribution = sourceAttribution
    }

    /// Whether this status belongs to the standalone helper rather than cmux.
    var helperOwnsPermissions: Bool {
        guard let sourceAttribution else { return false }
        return Self.helperAttributions.contains(sourceAttribution)
    }

    init?(structuredContent: [String: Any]) {
        guard
            let accessibility = structuredContent["accessibility"] as? Bool,
            let screenRecording = structuredContent["screen_recording"] as? Bool
        else {
            return nil
        }
        let sourceAttribution = (structuredContent["source"] as? [String: Any])?[
            "attribution"
        ] as? String
        if sourceAttribution == "caller" || sourceAttribution == "host" {
            // Never surface a host-owned grant as if it belonged to the helper.
            return nil
        }
        self.init(
            accessibility: accessibility,
            screenRecording: screenRecording,
            isKnown: true,
            sourceAttribution: sourceAttribution
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
