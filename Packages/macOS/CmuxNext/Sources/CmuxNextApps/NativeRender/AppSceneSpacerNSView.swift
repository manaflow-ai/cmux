import AppKit

/// `Spacer`: takes the room a horizontal stack has left; nothing in a vertical one (a section sizes
/// to fit its content).
final class AppSceneSpacerNSView: AppSceneNodeNSView {
    override var isSpacer: Bool { true }
}
