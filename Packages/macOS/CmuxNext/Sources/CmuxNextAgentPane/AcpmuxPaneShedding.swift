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

    /// Whether `text` is a notification the page can read again after a lag, and not one a host
    /// observer reads (a permission, a prompt's acceptance), which ``AcpmuxRequestIds`` must see,
    /// nor a prompt the person sent or a permission ask (``PageStreamShedding``).
    static func sheddable(_ text: String) -> Bool { rules.sheddable(text) }

    /// Whether `text` is a transcript record, whose seq the page's cursor follows.
    static func transcriptRecord(_ text: String) -> Bool { rules.transcriptRecord(text) }

    /// The top-level `method` of a frame with no top-level `id`; nil for a reply, a request, or a
    /// frame whose keys or method it cannot read without unescaping.
    static func notificationMethod(_ text: String) -> String? { rules.notificationMethod(text) }
}
