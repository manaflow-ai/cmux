import CmuxNextCompat
import Foundation
import CmuxPagePushBound

/// What the pane's transport does when its page falls a full queue behind the daemon
/// (``AgentPaneTransport/Limits``), or is held (nobody sees it, or it stopped draining), as acpmux
/// does for any slow reader (server/outbound.rs): stream notifications are left out, replies,
/// requests, prompts and permission asks never are (``PageStreamShedding`` lists them), and once
/// the page caught up it gets one `_acpmux/lagged` and reads again from its last record (direct.ts
/// `resyncAfterLag`).
///
/// Before, the transport closed the socket instead (`transport.inbound_overflow`). The page then
/// connected again and read its chat and the list anew, which filled the queue again: Leo's chat
/// reconnected every 4 to 9 seconds for minutes at a time (up to 156 closes in 10 minutes on
/// 2026-11-11), redrawing between a kept tail and the live chat each time. One ~31 MB list reply
/// alone took 31 of the queue's 32 MB.
nonisolated enum AcpmuxPaneShedding {
    private static let rules = PageStreamShedding()

    /// The notice the page gets once a shed episode ends: `watch` because list notices may be
    /// among the shed ones, so the page reads the list again too.
    static func lagMarker(dropped: Int) -> String { rules.lagMarker(dropped: dropped) }

    /// The notices a frozen page hears nothing of (``AcpmuxPaneSocket/setAsleep(_:)``): other chats'
    /// rows and machines, which the page reads again from its list cursor once it wakes. Never its own
    /// chat's stream, a reply, a request or a notice a host observer reads.
    /// `_acpmux/session_patch` is a row change in compact form (direct.ts chatDeltas.ts): left out with the whole
    /// rows it patches, which the page reads again when it wakes.
    static let listNotices: Set<String> = ["_acpmux/session_changed", "_acpmux/session_patch", "_acpmux/peer_state_changed"]

    /// The notice a page that slept gets when it wakes, after list notices were left out: the list
    /// and machines are read again (`watch`), its own chat is not (`sessionIds` names none: its stream
    /// was never left out). direct.ts `resyncAfterLag`.
    static func wakeMarker(dropped: Int) -> String {
        #"{"jsonrpc":"2.0","method":"_acpmux/lagged","params":{"dropped":\#(dropped),"reason":"page_asleep","watch":true,"sessionIds":[]}}"#
    }

    /// Whether `text` is a list notice a frozen page is spared (``listNotices``).
    static func sparedWhileAsleep(_ text: String) -> Bool {
        notificationMethod(text).map(listNotices.contains) ?? false
    }

    /// Whether `text` is a notification the page can read again after a lag: a top-level `method`
    /// and no top-level `id` (not a reply, not a request that waits on an answer), not one a host
    /// observer reads (a permission, a prompt's acceptance), which ``AcpmuxRequestIds`` must see,
    /// and not a prompt the person sent or a permission ask (``PageStreamShedding``).
    /// Anything it cannot read plainly (an escaped key or method) is kept.
    static func sheddable(_ text: String) -> Bool {
        sheddable(text, method: notificationMethod(text))
    }

    /// ``sheddable(_:)`` with the frame's ``notificationMethod(_:)`` already read.
    static func sheddable(_ text: String, method: String?) -> Bool {
        guard let method else { return false }
        if method == "_acpmux/event" {
            guard !text.utf8ContainsAny(AcpmuxRequestIds.eventObserverMarkers) else { return false }
        } else if AcpmuxRequestIds.observedNotificationMethods.contains(method) {
            return false
        }
        return rules.sheddable(text, method: method)
    }

    /// Whether `text` is a transcript record, whose seq the page's cursor follows.
    static func transcriptRecord(_ text: String) -> Bool { rules.transcriptRecord(text) }

    /// The top-level `method` of a frame with no top-level `id`; nil for a reply, a request, or a
    /// frame whose keys or method it cannot read without unescaping.
    static func notificationMethod(_ text: String) -> String? { rules.notificationMethod(text) }
}
