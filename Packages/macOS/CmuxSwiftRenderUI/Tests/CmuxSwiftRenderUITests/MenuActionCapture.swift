import CmuxSwiftRender

/// Collects dispatched actions from menu item activations (mutated on main).
final class MenuActionCapture: @unchecked Sendable {
    var actions: [ButtonAction] = []
}
