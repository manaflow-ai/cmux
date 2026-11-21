import Foundation

/// The values one resize gesture ends with, as one commit (`layout-sizes-batch-v1`): a key trade's two column
/// widths, a drag release's widths and ratios. The daemon applies them in order under the gesture's `transaction`
/// (one layout revision, one undo entry, shared with what the gesture sent before); if it refuses one value,
/// nothing changes.
public struct SetLayoutSizesRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "set-layout-sizes"
    public static let requiredCapability: String? = DaemonCapability.layoutSizesBatch.rawValue
    /// The most values the daemon takes in one command.
    public static let limit = 64

    /// One value: what `set-split-ratio` or `set-viewport-pane-width` sets alone, with the same ranges.
    public enum Value: Encodable, Sendable, Equatable {
        case ratio(SplitID, Double)
        /// The width of the column holding `pane`.
        case width(pane: PaneID, Double)

        private enum CodingKeys: String, CodingKey {
            case split, ratio, pane, width
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .ratio(split, ratio):
                try container.encode(split, forKey: .split)
                try container.encode(ratio, forKey: .ratio)
            case let .width(pane, width):
                try container.encode(pane, forKey: .pane)
                try container.encode(width, forKey: .width)
            }
        }
    }

    /// 1 to ``limit`` values of one screen, applied in order.
    public var values: [Value]
    public var transaction: UInt64

    public init(values: [Value], transaction: UInt64) {
        self.values = values
        self.transaction = transaction
    }
}
