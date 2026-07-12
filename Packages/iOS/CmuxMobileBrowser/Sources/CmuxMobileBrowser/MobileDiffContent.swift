#if canImport(UIKit)
import CmuxMobileSupport
import SwiftUI

struct MobileDiffContent: View {
    let state: MobileDiffState
    let reload: () -> Void

    var body: some View {
        if let errorMessage = state.errorMessage {
            ContentUnavailableView {
                Label(L10n.string("mobile.diff.loadFailed", defaultValue: "Couldn’t Load Diff"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button(L10n.string("mobile.common.retry", defaultValue: "Retry"), action: reload)
            }
        } else if state.isLoading, state.document == nil {
            ProgressView(L10n.string("mobile.diff.loading", defaultValue: "Loading changes…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.document != nil {
            MobileDiffWebView(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if state.isLoading {
                        ProgressView().controlSize(.small).padding(8)
                    }
                }
        } else {
            Color.clear
        }
    }
}
#endif
