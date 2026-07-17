internal import SwiftUI

struct ChangesErrorBanner: View {
    let error: ChangesErrorSnapshot
    let retry: @MainActor @Sendable () -> Void
    let useWorkingTree: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error.title, systemImage: iconName)
                .font(.headline)
            Text(error.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                if error.kind == .baseline {
                    Button(
                        String(localized: "diff.base.useWorkingTree", defaultValue: "Use Working tree", bundle: .module),
                        action: useWorkingTree
                    )
                    .buttonStyle(.borderedProminent)
                }
                Button(String(localized: "diff.action.retry", defaultValue: "Retry", bundle: .module), action: retry)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }

    private var iconName: String {
        switch error.kind {
        case .authentication: "person.crop.circle.badge.exclamationmark"
        case .capability: "arrow.down.circle"
        case .baseline: "point.3.connected.trianglepath.dotted"
        case .general: "wifi.exclamationmark"
        }
    }
}
