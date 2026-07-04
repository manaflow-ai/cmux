public import SwiftUI
public import CmuxUpdater

/// Hosts ``UpdateReadyToast`` in the sidebar, directly above the footer. Renders nothing (and
/// hit-tests nothing) while no toast is due or no actions host exists.
public struct UpdateReadyToastOverlay: View {
    private let model: UpdateStateModel
    private let actions: (any UpdateActionsHost)?

    /// Creates the overlay. `actions` is optional so call sites can pass a not-yet-wired host.
    public init(model: UpdateStateModel, actions: (any UpdateActionsHost)?) {
        self.model = model
        self.actions = actions
    }

    /// The overlay body, padded to align the toast with the sidebar footer.
    public var body: some View {
        if let actions {
            UpdateReadyToast(model: model, actions: actions)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
        }
    }
}
