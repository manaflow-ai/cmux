import Foundation

/// A split's divider drawn or not (`split-divider-visibility-v1`): a hidden divider draws no line
/// and still drags. The daemon keeps it on the split node, so it persists with the layout.
public struct SetDividerVisibleRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "set-divider-visible"
    public var split: SplitID
    public var visible: Bool
    public init(split: SplitID, visible: Bool) {
        self.split = split
        self.visible = visible
    }
}
