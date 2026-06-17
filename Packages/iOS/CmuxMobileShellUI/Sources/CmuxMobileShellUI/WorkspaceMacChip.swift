import CmuxMobileSupport
import SwiftUI

/// A small per-row "Mac" chip shown in the unified multi-Mac workspace list,
/// labeling which Mac owns the workspace. The Mac is a secondary dimension of a
/// flat list (not a navigation mode), so the chip is compact and unobtrusive.
///
/// Pure value view: it takes only the resolved label string, so it stays below
/// the `List` snapshot boundary without referencing any store.
struct WorkspaceMacChip: View {
    /// The resolved Mac display name (already non-empty; the caller falls back to
    /// a short device id when no friendly name is known).
    let name: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(
                format: L10n.string("mobile.workspace.macChip.a11y", defaultValue: "On %@"),
                name
            )
        )
    }

    /// Resolve a chip label for a workspace's owning Mac.
    ///
    /// Returns the friendly device name when known, otherwise the short device id
    /// (first 8 chars, matching ``RegistryDevice/title``). Returns `nil` for an
    /// empty/unscoped `deviceId` so a single-Mac (unscoped) row shows no chip.
    static func label(forDeviceID deviceID: String, names: [String: String]) -> String? {
        guard !deviceID.isEmpty else { return nil }
        if let name = names[deviceID], !name.isEmpty {
            return name
        }
        return String(deviceID.prefix(8))
    }
}
