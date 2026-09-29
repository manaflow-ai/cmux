import AppKit

/// Precomputed geometry and content for one transcript row at one width.
struct AcpmuxRowLayout {
    enum Surface: Equatable {
        case none
        case userBubble
        case assistantBubble
        case card
        case typing
    }

    let height: CGFloat
    let surfaceFrame: CGRect
    let textFrame: CGRect
    let text: NSAttributedString
    let surface: Surface
    let showsTail: Bool
    let isToggleable: Bool
    let dimmed: Bool
    let timestamp: String?
}
