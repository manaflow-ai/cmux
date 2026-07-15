import SwiftUI

struct DiffErrorBannerView: View {
    let kind: DiffScreenErrorKind
    let retry: @MainActor () -> Void
    let useWorkingTree: (@MainActor () -> Void)?
    let dismiss: (@MainActor () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let useWorkingTree {
                Button(useWorkingTreeLabel, action: useWorkingTree)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(retryLabel, action: retry)
                    .buttonStyle(.bordered)
            }
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dismissLabel)
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }

    private var title: String {
        let localized = DiffLocalized()
        return switch kind {
        case .unknownWorkspace:
            localized.string("diff.error.workspace.title", defaultValue: "Workspace unavailable")
        case .notGitRepository:
            localized.string("diff.error.repository.title", defaultValue: "Not a Git repository")
        case .baselineMissing:
            localized.string("diff.error.baseline.title", defaultValue: "Baseline unavailable")
        case .transport:
            localized.string("diff.error.transport.title", defaultValue: "Couldn’t load diff")
        }
    }

    private var message: String {
        let localized = DiffLocalized()
        return switch kind {
        case .unknownWorkspace:
            localized.string("diff.error.workspace.message", defaultValue: "This workspace is no longer available on the paired computer.")
        case .notGitRepository:
            localized.string("diff.error.repository.message", defaultValue: "This workspace is not a Git repository.")
        case .baselineMissing:
            localized.string("diff.error.baseline.message", defaultValue: "The selected comparison baseline is no longer available.")
        case .transport:
            localized.string("diff.error.transport.message", defaultValue: "The diff could not be loaded from the paired computer.")
        }
    }

    private var retryLabel: String {
        DiffLocalized().string("diff.action.retry", defaultValue: "Retry")
    }

    private var useWorkingTreeLabel: String {
        DiffLocalized().string("diff.error.baseline.fallback", defaultValue: "Use Working tree")
    }

    private var dismissLabel: String {
        DiffLocalized().string("diff.action.dismiss", defaultValue: "Dismiss")
    }
}
