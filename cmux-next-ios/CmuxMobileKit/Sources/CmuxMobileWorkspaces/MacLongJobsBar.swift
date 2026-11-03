#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// The Mac's long job while one runs (plans/cmux-next/long-jobs-DESIGN.md): an hourglass, the first job's
/// title and percent, and a bar when its size is known, at the bottom of the Workspaces list. It goes away
/// when no job runs. A job that blocks the Mac's start says the Mac is still starting, so a slow first list
/// reads as the cleanup it is, not as a failure.
struct MacLongJobsBar: View {
    let jobs: [MacLongJob]

    var body: some View {
        if let job = jobs.first {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "hourglass")
                        .foregroundStyle(theme.colors.label2)
                    Text(job.summary)
                        .font(theme.type.rowSubtitle)
                        .foregroundStyle(theme.colors.label)
                        .lineLimit(2)
                    if jobs.count > 1 {
                        Text("+\(jobs.count - 1)")
                            .font(theme.type.meta)
                            .foregroundStyle(theme.colors.label2)
                    }
                }
                if let percent = job.percent {
                    ProgressView(value: Double(percent), total: 100)
                        .progressViewStyle(.linear)
                }
                if job.blocks.contains("startup") {
                    Text("Your Mac's workspaces open when this finishes.")
                        .font(theme.type.meta)
                        .foregroundStyle(theme.colors.label2)
                }
            }
            .padding(.horizontal, theme.metrics.sideMargin)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("workspaces.longJobs")
        }
    }
}
#endif
