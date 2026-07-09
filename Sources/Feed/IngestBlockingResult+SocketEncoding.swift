import CMUXAgentLaunch
import Foundation

extension WorkstreamIngestBlockingResult {
    /// The `[String: Any]` JSON payload the `feed.push` socket handler emits for
    /// a blocking-ingest outcome. Byte-faithful port of the legacy
    /// `FeedSocketEncoding.payload(for:)`. Stays app-side because the resolved
    /// decision's
    /// own JSON shape comes from the package
    /// ``WorkstreamDecision/socketEncodedDictionary``.
    var socketEncodedDictionary: [String: Any] {
        switch self {
        case .acknowledged(let itemId):
            var dict: [String: Any] = ["status": "acknowledged"]
            if let itemId { dict["item_id"] = itemId.uuidString }
            return dict
        case .resolved(let itemId, let decision):
            var dict: [String: Any] = [
                "status": "resolved",
                "decision": decision.socketEncodedDictionary,
            ]
            if let itemId { dict["item_id"] = itemId.uuidString }
            return dict
        case .timedOut(let itemId):
            var dict: [String: Any] = ["status": "timed_out"]
            if let itemId { dict["item_id"] = itemId.uuidString }
            return dict
        }
    }
}
