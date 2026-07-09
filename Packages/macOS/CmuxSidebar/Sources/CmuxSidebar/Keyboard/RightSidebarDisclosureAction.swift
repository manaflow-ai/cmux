/// A tree-disclosure intent parsed from a right-sidebar keyboard event:
/// collapse the focused row's children, or expand them.
///
/// Pure, `Sendable` value type. The parsing that produces it lives on
/// `NSEvent` (see `NSEvent.rightSidebarDisclosureAction`).
public enum RightSidebarDisclosureAction: Sendable, Equatable {
    case collapse
    case expand
}
