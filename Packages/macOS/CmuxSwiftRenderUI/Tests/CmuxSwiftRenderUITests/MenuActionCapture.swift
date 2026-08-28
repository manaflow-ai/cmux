import CmuxSwiftRender

/// Collects dispatched actions from menu item activations (mutated on main).
@MainActor
final class MenuActionCapture {
    var actions: [ButtonAction] = []
}
