import CmuxHomeCore
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

    // MARK: The running indicator's folded steps (HomeTurnProgress); the agent chat's words

    static func turnRanCommands(_ n: Int) -> String {
        String(localized: "home.turn.ranCommands", defaultValue: "Ran \(n) commands", table: "CmuxHome", bundle: .module)
    }
    static func turnReadFiles(_ n: Int) -> String {
        String(localized: "home.turn.readFiles", defaultValue: "Read \(n) files", table: "CmuxHome", bundle: .module)
    }
    static func turnEditedFiles(_ n: Int) -> String {
        String(localized: "home.turn.editedFiles", defaultValue: "Edited \(n) files", table: "CmuxHome", bundle: .module)
    }
    static func turnRanSearches(_ n: Int) -> String {
        String(localized: "home.turn.ranSearches", defaultValue: "Ran \(n) searches", table: "CmuxHome", bundle: .module)
    }

    /// The message menu's permalink item (tree threads, cx-och3h).
    /// The remove button on an attachment in the message box (its help and accessibility label).
    static var removeAttachment: String {
        String(localized: "home.compose.removeAttachment", defaultValue: "Remove Attachment", table: "CmuxHome", bundle: .module)
    }
    /// The mic button in the message box at rest (its help and accessibility label).
    static var dictate: String {
        String(localized: "home.compose.dictate", defaultValue: "Dictate", table: "CmuxHome", bundle: .module)
    }
    /// The mic button while it records (a click stops and keeps the words).
    static var stopDictation: String {
        String(localized: "home.compose.stopDictation", defaultValue: "Stop Dictation", table: "CmuxHome", bundle: .module)
    }
    /// The return-key button beside the waveform while dictating: stop and keep the words.
    static var finishDictation: String {
        String(localized: "home.compose.finishDictation", defaultValue: "Finish Dictation", table: "CmuxHome", bundle: .module)
    }
    /// The empty message box while dictating, before any words arrive.
    static var listening: String {
        String(localized: "home.compose.listening", defaultValue: "Listening…", table: "CmuxHome", bundle: .module)
    }
    /// The compose field's send button (its help and accessibility label).
    static var send: String {
        String(localized: "home.compose.send", defaultValue: "Send", table: "CmuxHome", bundle: .module)
    }
    /// The compose button after the person stops the Chief's turn.
    static var continueTurn: String {
        String(localized: "home.compose.continue", defaultValue: "Continue", table: "CmuxHome", bundle: .module)
    }
    /// Reply to Selection (ChatController+ReplyQuote.swift): the menu item, the card's line and its remove button.
    static var replyToSelection: String {
        String(localized: "home.message.replyToSelection", defaultValue: "Reply to Selection", table: "CmuxHome", bundle: .module)
    }
    /// The card's line over the quote: "Replying to Chief".
    static func replyingTo(_ name: String) -> String {
        String(format: String(localized: "home.replyQuote.replyingTo", defaultValue: "Replying to %@", table: "CmuxHome", bundle: .module), name)
    }
    /// The card's line when the quoted message's sender is unknown.
    static var replyingToSelection: String {
        String(localized: "home.replyQuote.replyingToSelection", defaultValue: "Replying to Selection", table: "CmuxHome", bundle: .module)
    }
    static var replyQuoteRemove: String {
        String(localized: "home.replyQuote.remove", defaultValue: "Remove Quote", table: "CmuxHome", bundle: .module)
    }
    static var copyLink: String {
        String(localized: "home.message.copyLink", defaultValue: "Copy Link", table: "CmuxHome", bundle: .module)
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

    /// The context menu item on my "Not Delivered" message that sends it again.
    static var tryAgain: String {
        String(localized: "home.menu.tryAgain", defaultValue: "Try Again", table: "CmuxHome", bundle: .module)
    }

    /// The context menu item on a person's committed Chief message: run the
    /// Chief's turn again for that message (distinct from a failed send).
    static var retryReply: String {
        String(localized: "home.menu.retryReply", defaultValue: "Retry Reply", table: "CmuxHome", bundle: .module)
    }

    /// The context menu item that sends a bubble's text to another chat or agent.
    static var forward: String {
        String(localized: "home.menu.forward", defaultValue: "Forward…", table: "CmuxHome", bundle: .module)
    }

    /// The context menu item on my "Not Delivered" message that drops it.
    static var deleteFailed: String {
        String(localized: "home.menu.deleteFailed", defaultValue: "Delete", table: "CmuxHome", bundle: .module)
    }

    static var playVideo: String { String(localized: "home.video.play", defaultValue: "Play Video", table: "CmuxHome", bundle: .module) }
    static var viewVideoLarger: String {
        String(localized: "home.video.viewLarger", defaultValue: "View Larger", table: "CmuxHome", bundle: .module)
    }
    static var closeVideoViewer: String {
        String(localized: "home.video.closeViewer", defaultValue: "Close Video", table: "CmuxHome", bundle: .module)
    }
    static var pauseVideo: String { String(localized: "home.video.pause", defaultValue: "Pause Video", table: "CmuxHome", bundle: .module) }
    /// An attachment's Copy (the file and an image's pixels): Messages' own Copy title.
    static var copyAttachment: String { Strings.menuCopy }
    static var saveAttachmentAs: String {
        String(localized: "home.attachment.saveAs", defaultValue: "Save As…", table: "CmuxHome", bundle: .module)
    }
    /// An agent-message fold's link while folded: how many messages it holds ("Agent messages (6)").
    static func showAgentMessages(_ count: Int) -> String {
        String(format: String(localized: "home.agentMessages.show", defaultValue: "Agent messages (%lld)",
                              table: "CmuxHome", bundle: .module), count)
    }
    /// The same link while its messages show in full.
    static func hideAgentMessages(_ count: Int) -> String {
        String(format: String(localized: "home.agentMessages.hide", defaultValue: "Hide agent messages (%lld)",
                              table: "CmuxHome", bundle: .module), count)
    }
    /// A notes row's label: why its `count` agents stopped with no report ("Disconnected (5)");
    /// nil `reason`: they stopped for different reasons.
    static func agentNotes(_ reason: HomeAgentMessageRow.StatusNote?, _ count: Int) -> String {
        let format: String
        switch reason {
        case .stopped(let session)? where session == "Disconnected":
            format = String(localized: "home.agentNotes.disconnected", defaultValue: "Disconnected (%lld)", table: "CmuxHome", bundle: .module)
        case .stopped(let session)? where session == "Closed":
            format = String(localized: "home.agentNotes.closed", defaultValue: "Session closed (%lld)", table: "CmuxHome", bundle: .module)
        case .gone?:
            format = String(localized: "home.agentNotes.gone", defaultValue: "Gone (%lld)", table: "CmuxHome", bundle: .module)
        case .unreadable?:
            format = String(localized: "home.agentNotes.unreadable", defaultValue: "Report unreadable (%lld)", table: "CmuxHome", bundle: .module)
        default:
            format = String(localized: "home.agentNotes.stopped", defaultValue: "Stopped without a report (%lld)", table: "CmuxHome", bundle: .module)
        }
        return String(format: format, count)
    }
    /// A link's Open Link and Copy Link Address rows (a link in text, a link card, a link preview).
    static var openLink: String {
        String(localized: "home.menu.openLink", defaultValue: "Open Link", table: "CmuxHome", bundle: .module)
    }
    static var copyLinkAddress: String {
        String(localized: "home.menu.copyLinkAddress", defaultValue: "Copy Link Address", table: "CmuxHome", bundle: .module)
    }
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

    // MARK: The Chief's plan card (HomeTableRowProvider.swift)

    /// The card's header: "Plan", or "Plan · 3 active" while some steps still run. Never a step count.
    static func planHeader(steps: Int, active: Int) -> String {
        if active == 0 {
            return String(localized: "home.plan.title", defaultValue: "Plan", table: "CmuxHome", bundle: .module)
        }
        return String(format: String(localized: "home.plan.activeCount", defaultValue: "Plan · %lld active", table: "CmuxHome", bundle: .module), active)
    }

    /// A step's state pill.
    static func planState(_ state: ChiefPlanStep.State) -> String {
        switch state {
        case .working: String(localized: "home.plan.state.working", defaultValue: "Working", table: "CmuxHome", bundle: .module)
        case .needsInput: String(localized: "home.plan.state.needsInput", defaultValue: "Needs You", table: "CmuxHome", bundle: .module)
        case .waitingOnCI: String(localized: "home.plan.state.waitingOnCI", defaultValue: "Waiting on CI", table: "CmuxHome", bundle: .module)
        case .ciFailed: String(localized: "home.plan.state.ciFailed", defaultValue: "CI Failed", table: "CmuxHome", bundle: .module)
        case .inReview: String(localized: "home.plan.state.inReview", defaultValue: "In Review", table: "CmuxHome", bundle: .module)
        case .landed: String(localized: "home.plan.state.landed", defaultValue: "Landed", table: "CmuxHome", bundle: .module)
        case .done: String(localized: "home.plan.state.done", defaultValue: "Done", table: "CmuxHome", bundle: .module)
        case .failed: String(localized: "home.plan.state.failed", defaultValue: "Failed", table: "CmuxHome", bundle: .module)
        }
    }

    /// The card's click menu: the owner's chat ("Open a12's Chat").
    static func planOpenOwner(_ owner: String) -> String {
        String(format: String(localized: "home.plan.openOwner", defaultValue: "Open %@’s Chat", table: "CmuxHome", bundle: .module), owner)
    }

    /// The card's click menu: a link ("Open #22590", "Open github.com").
    static func planOpenLink(_ name: String) -> String {
        String(format: String(localized: "home.plan.openLink", defaultValue: "Open %@", table: "CmuxHome", bundle: .module), name)
    }
}
