import Foundation

/// cmux's own transcript strings (Resources/CmuxHome.xcstrings, every app
/// language), for the few places a vendored file says something MessagesLab
/// does not (marked `cmux:` there).
enum CmuxStrings {
    // MARK: The status line's turn details (HomeTurnStatusPopover)

    static var turnTitle: String {
        String(localized: "home.turn.title", defaultValue: "This Turn", table: "CmuxHome", bundle: .module)
    }
    /// The turn's time so far: "Total 1m 5s".
    static func turnTotal(_ elapsed: String) -> String {
        String(format: String(localized: "home.turn.total", defaultValue: "Total %@", table: "CmuxHome", bundle: .module), elapsed)
    }
    /// The running step's state in the list.
    static var turnNow: String {
        String(localized: "home.turn.now", defaultValue: "now", table: "CmuxHome", bundle: .module)
    }
    /// The status line's help and accessibility label: a click shows the steps.
    static var turnShow: String {
        String(localized: "home.turn.show", defaultValue: "Show This Turn's Steps", table: "CmuxHome", bundle: .module)
    }
    /// A step under a second.
    static var turnUnderOneSecond: String {
        String(localized: "home.turn.under1s", defaultValue: "<1s", table: "CmuxHome", bundle: .module)
    }

    /// The message menu's permalink item (tree threads, cx-och3h).
    static var copyLink: String {
        String(localized: "home.message.copyLink", defaultValue: "Copy Link", table: "CmuxHome", bundle: .module)
    }
    /// The placeholder of the thread header's rename field.
    static var threadTitlePlaceholder: String {
        String(localized: "home.thread.titlePlaceholder", defaultValue: "Thread Title", table: "CmuxHome", bundle: .module)
    }
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

    /// A reply's thread root is not delivered yet (my send still going): the thread view closes.
    static var threadRootNotReady: String {
        String(localized: "home.thread.rootNotReady", defaultValue: "You can reply in this thread once its first message is delivered.",
               table: "CmuxHome", bundle: .module)
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
