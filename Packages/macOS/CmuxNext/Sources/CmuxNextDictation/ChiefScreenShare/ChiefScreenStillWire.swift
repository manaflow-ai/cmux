public import Foundation

/// The cmux Computer Use helper's host-only `display_still` request and reply
/// (scripts/cmux-cua-display-still.patch), and how its refusals read.
public struct ChiefScreenStillWire {
    public init() {}
    /// The method name on the helper's socket.
    public static let method = "display_still"
    /// The helper's refusal when Screen Recording is not allowed for it.
    public static let notGranted = "screen_recording_not_granted"

    /// A `display_still` reply that is not a still.
    public struct Malformed: Error, Equatable {
        public init() {}
    }

    /// The `display_still` arguments: the apps to leave out go by bundle id (the helper finds their
    /// processes, so cmux never scans processes) plus this app's own process.
    public static func arguments(_ request: ChiefScreenStillRequest) -> [String: Any] {
        var args: [String: Any] = ["width": request.width, "exclude_pids": [Int(request.exclusions.ownProcess)],
                                   "exclude_bundle_ids": request.exclusions.bundleIDs.sorted(),
                                   "exclude_bundle_prefixes": [ChiefScreenShareExclusions.cmuxPrefix],
                                   "threshold": request.threshold, "quality": request.quality]
        if let previous = request.previous { args["previous_signature"] = Data(previous.pixels).base64EncodedString() }
        return args
    }

    /// A `display_still` reply as a still; nil when it is malformed.
    public static func still(_ reply: [String: Any]) -> ChiefScreenStill? {
        guard let encoded = reply["signature"] as? String, let bytes = Data(base64Encoded: encoded),
              let signature = VoiceRoomFrameSignature(pixels: [UInt8](bytes)) else { return nil }
        var jpeg: Data?
        if reply["changed"] as? Bool == true {
            guard let data = (reply["jpeg"] as? String).flatMap({ Data(base64Encoded: $0) }), !data.isEmpty else { return nil }
            jpeg = data
        }
        return ChiefScreenStill(signature: signature, jpeg: jpeg, app: nonEmpty(reply["front_app"]),
                                window: nonEmpty(reply["front_window"]))
    }

    /// The interruption a helper refusal means, nil for any other refusal.
    public static func interruption(refusal: String) -> ChiefScreenCaptureInterruption? {
        refusal.contains(notGranted) ? .notAllowed : nil
    }

    private static func nonEmpty(_ value: Any?) -> String? { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
}
