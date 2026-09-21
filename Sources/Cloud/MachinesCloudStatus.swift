import SwiftUI

/// Main's Cloud toolbar status, driven by values from the combined Cloud/Devices panel.
struct MachinesCloudStatus: View {
    let activeOperation: String?
    let staleError: String?
    let treeError: String?
    let plan: MachinePlanSnapshot?
    let onDismissStale: (String) -> Void

    var body: some View {
        Group {
            if let operation = activeOperation {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(operation)
                        .cmuxFont(size: 11)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else if let error = staleError {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .semibold))
                    Text(String(localized: "machines.unavailable.stale", defaultValue: "Cloud unreachable \u{2014} showing last known"))
                        .cmuxFont(size: 11)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundColor(.orange.opacity(0.9))
                .help(error)
                .cloudErrorCopyMenu(error)
                CloudBannerDismissButton { onDismissStale(error) }
            } else if let error = treeError {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .semibold))
                    Text(error)
                        .cmuxFont(size: 11)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .foregroundColor(.orange.opacity(0.9))
                .help(error)
                .cloudErrorCopyMenu(error)
            } else if let plan {
                MachinePlanMeter(plan: plan)
            }
        }
    }
}
