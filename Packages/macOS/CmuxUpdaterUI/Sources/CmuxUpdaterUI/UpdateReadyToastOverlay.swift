public import SwiftUI
public import CmuxUpdater

/// Hosts ``UpdateReadyToast`` in the sidebar, directly above the footer. Renders nothing (and
/// hit-tests nothing) while no toast is due or no actions host exists.
public struct UpdateReadyToastOverlay: View {
    private let model: UpdateStateModel
    private let actions: (any UpdateActionsHost)?
    private let onHeightChange: (CGFloat) -> Void

    /// Creates the overlay. `actions` is optional so call sites can pass a not-yet-wired host.
    public init(
        model: UpdateStateModel,
        actions: (any UpdateActionsHost)?,
        onHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.model = model
        self.actions = actions
        self.onHeightChange = onHeightChange
    }

    /// The overlay body. The visible toast carries its own margins so they enter and exit
    /// with the card's transition; a hidden toast contributes exactly zero height.
    public var body: some View {
        let isVisible = model.updateReadyToastInstalling != nil
        ZStack {
            if let actions {
                UpdateReadyToast(model: model, actions: actions)
            }
        }
        .background(UpdateReadyToastHeightReporter(isVisible: isVisible))
        .onPreferenceChange(UpdateReadyToastHeightPreferenceKey.self, perform: onHeightChange)
    }
}

private struct UpdateReadyToastHeightReporter: View {
    let isVisible: Bool

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: UpdateReadyToastHeightPreferenceKey.self,
                value: isVisible ? proxy.size.height : 0
            )
        }
    }
}

private struct UpdateReadyToastHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
