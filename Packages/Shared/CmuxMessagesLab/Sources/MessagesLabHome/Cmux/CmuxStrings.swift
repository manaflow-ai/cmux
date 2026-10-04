import Foundation

/// cmux's own transcript strings (Resources/CmuxHome.xcstrings, every app
/// language), for the few places a vendored file says something MessagesLab
/// does not (marked `cmux:` there).
enum CmuxStrings {
    static var notDelivered: String {
        String(localized: "label.notDelivered", defaultValue: "Not Delivered", table: "CmuxHome", bundle: .module)
    }
    static var mayNotHaveBeenDelivered: String {
        String(localized: "label.mayNotHaveBeenDelivered", defaultValue: "May Not Have Been Delivered", table: "CmuxHome", bundle: .module)
    }

    /// The reason HomeMapping gives a failed send that reached the owner and
    /// got no answer (`TranscriptItem.mayHaveBeenDelivered`).
    static let mayHaveBeenDeliveredReason = "cmux.mayHaveBeenDelivered"

    /// The label under a failed message of mine (Layout's "failed:" row).
    static func failedLabel(_ status: DeliveryStatus?) -> String {
        if case .failed(let reason) = status, reason == mayHaveBeenDeliveredReason { return mayNotHaveBeenDelivered }
        return notDelivered
    }
}
