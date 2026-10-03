public import CoreGraphics
public import Foundation

/// Scroll gesture phases (NSEvent.Phase and UIGestureRecognizer states map here).
public enum HomeScrollPhase: Sendable, Hashable {
    case none, mayBegin, began, changed, ended, cancelled
}

/// Platform-neutral input. Hosts translate their events into these; the
/// core never sees NSEvent, UIEvent or a text-input protocol. Changes to
/// shared state leave the controller as CmuxHomeCore `HomeIntent`s.
public enum HomeInput: Sendable, Hashable {
    /// `deltaY` > 0 reveals older messages (content follows the fingers down).
    case scroll(deltaY: CGFloat, phase: HomeScrollPhase, momentum: HomeScrollPhase)
    /// Momentum for hosts without system momentum events: pt/s at gesture end.
    /// The host then calls `stepMomentum` once per display frame while it returns true.
    case fling(velocity: CGFloat)
    case insertText(String, replacing: NSRange?)
    case setMarkedText(String, selected: NSRange, replacing: NSRange?)
    case unmarkText
    case deleteBackward
    case insertNewline
    case moveCaret(Int)
    /// Sends the draft (Return). Commits marked text first instead when there is any.
    case send
}

/// One accessibility element: a transcript row or the compose field.
public struct HomeAXItem: Sendable, Hashable {
    public enum Role: Sendable, Hashable { case staticText, textArea }

    public var id: String
    public var role: Role
    public var label: String
    public var value: String
    /// Viewport coordinates, points, top-left origin.
    public var frame: CGRect

    public init(id: String, role: Role, label: String, value: String, frame: CGRect) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.frame = frame
    }
}
