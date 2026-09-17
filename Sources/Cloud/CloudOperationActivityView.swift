import AppKit
import SwiftUI

/// The view receives values, so a growing diagnostic history does not invalidate machine rows.
struct CloudOperationActivityView: View {
    let operations: [CloudOperationSnapshot]
    let dismiss: @MainActor (UUID) -> Void

    private var visible: [CloudOperationSnapshot] {
        operations.filter(\.isVisibleInMachinesPanel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(visible.suffix(3))) { operation in
                HStack(alignment: .top, spacing: 6) {
                    if operation.isRunning { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(operation.operation.label).font(.caption.bold())
                        Text(operation.isRunning ? operation.currentPhase.label : (operation.failure ?? operation.steps.last(where: { $0.failure != nil })?.failure ?? .unknown).label)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if !operation.isRunning {
                        Button { dismiss(operation.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "cloud.operation.dismiss", defaultValue: "Dismiss operation"))
                    }
                }
                .cloudErrorCopyMenu(operation.needsAttention ? operation.copyableError : nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier("CloudOperationActivity")
    }
}
