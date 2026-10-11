import CmuxNextDesign
import SwiftUI

/// Reads the layout tunable and the resolved colors in a tracked scope, so a
/// Debug Settings or theme change updates the panel live.
struct FeedRoot: View {
    let model: FeedModel
    let appearance: FeedAppearance
    var layoutOverride: FeedLayout?

    var body: some View {
        FeedView(model: model, layout: layoutOverride ?? FeedTunables.layout.value)
            .environment(\.feedColors, appearance.colors)
            .tint(appearance.colors.primary)
    }
}

/// The panel: one of the prototype layouts over the same model, the
/// disconnected banner, and the refusal notice.
struct FeedView: View {
    let model: FeedModel
    let layout: FeedLayout
    @Environment(\.feedColors) private var colors

    var body: some View {
        VStack(spacing: 0) {
            if case let .disconnected(reason) = model.connection {
                FeedBanner(text: reason.isEmpty ? FeedStrings.disconnected : reason)
            }
            switch layout {
            case .list: FeedListView(model: model)
            case .inbox: FeedInboxView(model: model)
            }
        }
        .background(colors.background)
        .overlay(alignment: .bottom) {
            if let reject = model.lastReject {
                FeedToast(text: FeedStrings.reject(reject)) { model.clearReject() }
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .animation(Motion.animation(.fadeIn), value: model.lastReject)
    }
}

/// A line above the content: the owner is unreachable.
struct FeedBanner: View {
    let text: String
    @Environment(\.feedColors) private var colors

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(colors.attention).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11.5)).foregroundStyle(colors.secondary)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(colors.attention.opacity(0.08))
    }
}
