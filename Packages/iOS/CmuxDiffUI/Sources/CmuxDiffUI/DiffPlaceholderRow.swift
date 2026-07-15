import SwiftUI

struct DiffPlaceholderRow: View {
    let kind: DiffPlaceholderKind
    let action: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: imageName)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let buttonLabel {
                Button(buttonLabel, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var imageName: String {
        switch kind {
        case .binary: "doc.fill"
        case .large: "doc.badge.ellipsis"
        case .renameOnly: "arrow.right"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var message: String {
        let localized = DiffLocalized()
        return switch kind {
        case .binary:
            localized.string("diff.state.binary", defaultValue: "Binary file not shown")
        case .large:
            localized.string("diff.state.large", defaultValue: "This diff is large. Load it when you're ready.")
        case .renameOnly:
            localized.string("diff.state.renameOnly", defaultValue: "File renamed without content changes")
        case let .failed(message):
            message
        }
    }

    private var buttonLabel: String? {
        let localized = DiffLocalized()
        return switch kind {
        case .large:
            localized.string("diff.action.load", defaultValue: "Load diff")
        case .failed:
            localized.string("diff.action.retry", defaultValue: "Retry")
        case .binary, .renameOnly:
            nil
        }
    }
}
