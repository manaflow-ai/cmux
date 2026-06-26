import Foundation

extension BidirectionalCollection where Element == WorkstreamItem {
    /// Returns the id of the most recent item whose actionable payload
    /// (`.permissionRequest`, `.exitPlan`, or `.question`) carries the given
    /// `requestId`, searching newest-first. Non-actionable payloads are ignored.
    public func mostRecentActionableItemID(forRequestID requestId: String) -> UUID? {
        for item in reversed() {
            switch item.payload {
            case .permissionRequest(let rid, _, _, _) where rid == requestId:
                return item.id
            case .exitPlan(let rid, _, _) where rid == requestId:
                return item.id
            case .question(let rid, _) where rid == requestId:
                return item.id
            default:
                continue
            }
        }
        return nil
    }
}
