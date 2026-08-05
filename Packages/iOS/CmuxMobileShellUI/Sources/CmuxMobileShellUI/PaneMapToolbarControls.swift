import CmuxMobileSupport
import SwiftUI

struct PaneMapRefreshToolbarButton: View {
    let isRefreshing: Bool
    let refresh: () -> Void

    var body: some View {
        Button(action: refresh) {
            Group {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .frame(width: 24, height: 24)
        }
        .frame(width: PaneMapToolbarMetrics.refreshWidth, height: PaneMapToolbarMetrics.height)
        .disabled(isRefreshing)
        .accessibilityLabel(L10n.string("mobile.paneMap.refresh", defaultValue: "Refresh"))
        .accessibilityIdentifier("MobilePaneMapRefresh")
    }
}

struct PaneMapDoneToolbarButton: View {
    let done: () -> Void

    var body: some View {
        Button(action: done) {
            Text(L10n.string("mobile.paneMap.done", defaultValue: "Done"))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)
        }
        .frame(width: PaneMapToolbarMetrics.doneWidth, height: PaneMapToolbarMetrics.height)
        .accessibilityLabel(L10n.string("mobile.paneMap.done", defaultValue: "Done"))
        .accessibilityIdentifier("MobilePaneMapDone")
    }
}
