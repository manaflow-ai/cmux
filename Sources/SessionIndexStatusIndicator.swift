import SwiftUI

/// Shared 6×6 status circle used by full Vault rows and their popovers.
/// Active sessions are green; inactive history is gray in every grouping.
struct SessionStatusIndicator: View {
    let model: SessionIndexStatusIndicatorModel

    init(isInPane: Bool, liveStatus: VaultSessionLiveStatus?) {
        model = .make(isInPane: isInPane, liveStatus: liveStatus)
    }

    var body: some View {
        Circle()
            .fill(model.color)
            .frame(width: 6, height: 6)
            .help(model.label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(model.label))
    }
}
