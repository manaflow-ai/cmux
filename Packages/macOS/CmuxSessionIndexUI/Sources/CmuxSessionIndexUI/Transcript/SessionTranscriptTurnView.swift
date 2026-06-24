public import SwiftUI

import CmuxSessionIndex

/// One transcript turn row: the role label/marker on the left, the turn text on the right.
///
/// `roleLabel` is the app-resolved localized speaker label (empty on continuation rows);
/// it is passed in rather than read from the role so this view stays `Equatable` for the
/// `LazyVStack` snapshot-boundary optimization (no store reference below the list).
struct SessionTranscriptTurnView: View, Equatable {
    let row: SessionTranscriptDisplayRow
    let roleLabel: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 3) {
                Text(row.isContinuation ? "" : roleLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(row.role.foregroundColor)
                    .lineLimit(1)
                    .frame(width: 58, alignment: .trailing)
                if row.isContinuation {
                    Circle()
                        .fill(row.role.foregroundColor.opacity(0.38))
                        .frame(width: 3, height: 3)
                }
            }
            Text(row.text)
                .font(row.role.bodyFont)
                .foregroundColor(.primary.opacity(0.92))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(row.role.foregroundColor.opacity(0.46))
                .frame(width: 2)
        }
        .background(row.role.backgroundColor)
    }
}
