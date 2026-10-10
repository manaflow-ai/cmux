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

    /// Under the field while a send waits for the owner to name its conversation (cx-ebm.55).
    static var waitingForChief: String {
        String(localized: "home.send.waitingForChief", defaultValue: "Waiting for the Chief to connect…", table: "CmuxHome", bundle: .module)
    }
    static var waitingToConnect: String {
        String(localized: "home.send.waitingToConnect", defaultValue: "Waiting to connect…", table: "CmuxHome", bundle: .module)
    }
    /// Home moved the typed text from the cache's Chief conversation to the live Chief.
    static var chiefRestarted: String {
        String(localized: "home.send.chiefRestarted", defaultValue: "The Chief restarted. Press Return to send.", table: "CmuxHome", bundle: .module)
    }

    /// The context menu item that cancels my send while it uploads or after it failed.
    static var cancelUpload: String {
        String(localized: "home.menu.cancelUpload", defaultValue: "Cancel Upload", table: "CmuxHome", bundle: .module)
    }

    static var playVideo: String { String(localized: "home.video.play", defaultValue: "Play Video", table: "CmuxHome", bundle: .module) }
    static var pauseVideo: String { String(localized: "home.video.pause", defaultValue: "Pause Video", table: "CmuxHome", bundle: .module) }
    static var openInDefaultApp: String {
        String(localized: "home.menu.openInDefaultApp", defaultValue: "Open in Default App", table: "CmuxHome", bundle: .module)
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
