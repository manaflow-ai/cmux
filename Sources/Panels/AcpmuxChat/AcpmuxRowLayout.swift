import AppKit

/// Precomputed geometry and laid-out text for one transcript row at one width.
///
/// Built on a layout worker or the main thread and immutable after that; the main thread
/// is the only user once it is cached.
struct AcpmuxRowLayout: @unchecked Sendable {
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
    let textLayout: AcpmuxTextLayout
    let surface: Surface
    let showsTail: Bool
    let isToggleable: Bool
    let dimmed: Bool
    let timestamp: String?
    /// The precomputed surface outline, cached with the layout (so by row size and group position).
    var surfacePath: CGPath?
    /// The failed-send retry affordance, for a user message that was not delivered.
    var showsRetry = false
}
