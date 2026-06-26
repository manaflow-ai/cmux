import Foundation
public import SwiftUI

/// Dashed separator between pending items and resolved ones.
public struct ResolvedDivider: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 8) {
            line
            Text(String(localized: "feed.divider.resolved", defaultValue: "Resolved", bundle: .main))
                .font(.system(size: 10, weight: .medium))
                .tracking(0.5)
                .foregroundColor(.secondary.opacity(0.7))
            line
        }
        .padding(.vertical, 2)
    }

    private var line: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}
