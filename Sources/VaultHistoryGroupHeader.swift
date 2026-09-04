import AppKit
import CmuxFoundation
import CmuxVaultHistory
import SwiftUI

/// Value-only pinned header rendered below the History lazy-list boundary.
struct VaultHistoryGroupHeader: View, Equatable {
    let title: String
    let count: Int
    let key: VaultHistoryGroupKey
    /// Stable value snapshot of the host chrome color. Keeping a string here
    /// avoids carrying an AppKit reference below the lazy-list boundary.
    let backgroundHex: String?

    init(
        title: String,
        count: Int,
        key: VaultHistoryGroupKey = .date,
        backgroundHex: String? = nil
    ) {
        self.title = title
        self.count = count
        self.key = key
        self.backgroundHex = backgroundHex
    }

    nonisolated static func == (
        lhs: VaultHistoryGroupHeader,
        rhs: VaultHistoryGroupHeader
    ) -> Bool {
        lhs.title == rhs.title
            && lhs.count == rhs.count
            && lhs.key == rhs.key
            && lhs.backgroundHex == rhs.backgroundHex
    }

    var body: some View {
        HStack(spacing: 8) {
            CmuxSystemSymbolImage(
                magnified: key.symbolName,
                pointSize: 14,
                weight: .regular
            )
            .foregroundColor(.secondary)
            Text(title)
                .cmuxFont(size: 12, weight: .semibold)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(count, format: .number)
                .cmuxFont(size: 11, weight: .medium, monospacedDigit: true)
                .foregroundStyle(.tertiary)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Pinned headers need an opaque backing. Use the same resolved chrome
        // color as the host so the header does not introduce a light system
        // bar over a custom terminal theme.
        .background {
            Rectangle()
                .fill(headerBackground)
        }
        .clipped()
    }

    private var headerBackground: Color {
        Color(nsColor: NSColor(hex: backgroundHex ?? "") ?? .windowBackgroundColor)
    }
}
