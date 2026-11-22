public import AppKit

#if DEBUG
/// The AppKit cursor a page cursor (`rb.cursor`, a CSS cursor name) shows.
/// The mapping is plain data so a headless test can check it; only
/// ``cursor`` touches `NSCursor`, which needs a GUI session.
public nonisolated enum RemoteBrowserCursorShape: Sendable, Equatable {
    case arrow
    case pointingHand
    case iBeam
    case crosshair
    case openHand
    case closedHand
    case operationNotAllowed
    case dragCopy
    case dragLink
    case contextualMenu
    case resizeLeftRight
    case resizeUpDown

    /// Unknown names and custom images (the image cache is r3 work) show
    /// the arrow.
    public init(css kind: String) {
        switch kind {
        case "pointer", "hand": self = .pointingHand
        case "text", "vertical-text": self = .iBeam
        case "crosshair": self = .crosshair
        case "grab": self = .openHand
        case "grabbing": self = .closedHand
        case "not-allowed", "no-drop": self = .operationNotAllowed
        case "copy": self = .dragCopy
        case "alias": self = .dragLink
        case "context-menu": self = .contextualMenu
        case "col-resize", "ew-resize", "e-resize", "w-resize": self = .resizeLeftRight
        case "row-resize", "ns-resize", "n-resize", "s-resize": self = .resizeUpDown
        default: self = .arrow
        }
    }

    @MainActor public var cursor: NSCursor {
        switch self {
        case .arrow: .arrow
        case .pointingHand: .pointingHand
        case .iBeam: .iBeam
        case .crosshair: .crosshair
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .operationNotAllowed: .operationNotAllowed
        case .dragCopy: .dragCopy
        case .dragLink: .dragLink
        case .contextualMenu: .contextualMenu
        case .resizeLeftRight: .resizeLeftRight
        case .resizeUpDown: .resizeUpDown
        }
    }
}
#endif
