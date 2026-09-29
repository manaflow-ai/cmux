import SwiftUI

/// A value-only row that cannot subscribe to ledger mutations across a lazy-list boundary.
struct ReviewFindingRow: View {
    let finding: ReviewFindingItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                Text(verbatim: finding.severity).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(verbatim: finding.title).font(.callout.bold())
            }
            Text(verbatim: finding.status).font(.caption).foregroundStyle(.secondary)
            Text(String(localized: "review.finding.evidence", defaultValue: "Claims and challenge"))
                .font(.caption.bold())
            ForEach(Array(finding.claims.enumerated()), id: \.offset) { _, claim in
                Text(verbatim: claim).font(.caption).textSelection(.enabled)
            }
            Text(verbatim: finding.paths.joined(separator: "\n"))
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if !finding.isVerified {
                Text(String(localized: "review.finding.unverified", defaultValue: "No executable verification recorded"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
        }
        .accessibilityIdentifier("review.finding.\(finding.id)")
    }
}
