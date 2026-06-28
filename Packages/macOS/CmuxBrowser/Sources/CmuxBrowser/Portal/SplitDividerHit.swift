public import AppKit

/// The result of hit-testing a point against the split-view dividers beneath
/// the browser window portal.
///
/// The portal host pulls split-divider drags through to the app's underlying
/// `NSSplitView` layout, but keeps WebKit inspector/internal split dividers
/// interactive. `isInHostedContent` distinguishes the two: a hit on a split
/// view that descends from the portal host belongs to hosted web content and
/// must stay interactive, while a hit outside the host should pass through to
/// the app split.
public struct SplitDividerHit: Equatable {
    /// Orientation of the split-view divider under the pointer, which selects
    /// the resize cursor.
    public enum Kind: Equatable {
        case vertical
        case horizontal

        /// The resize cursor matching this divider's orientation.
        public var cursor: NSCursor {
            switch self {
            case .vertical: return .resizeLeftRight
            case .horizontal: return .resizeUpDown
            }
        }
    }

    /// The orientation of the divider that was hit.
    public let kind: Kind
    /// Whether the hit divider lives inside the portal-hosted web content (and
    /// must remain interactive) rather than in the app's split layout.
    public let isInHostedContent: Bool

    /// Create a split-divider hit result.
    public init(kind: Kind, isInHostedContent: Bool) {
        self.kind = kind
        self.isInHostedContent = isInHostedContent
    }
}
