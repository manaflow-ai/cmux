import Foundation

/// The bounded actions available when reconciling a shortcut-row offset.
enum AccessoryOffsetDecision: Equatable {
    case deferUntilScrollEnds
    case leaveUnchanged
    case set(CGFloat)
}
