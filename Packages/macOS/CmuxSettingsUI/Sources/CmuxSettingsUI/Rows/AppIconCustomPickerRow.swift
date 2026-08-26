import Foundation
import CmuxFoundation
import SwiftUI

/// Settings control for an optional user-provided Dock/app-switcher image.
///
/// The built-in Automatic / Light / Dark tiles remain in
/// ``AppIconPickerRow``. Keeping the file action in its own row makes the
/// existing mode picker stable while making the custom override explicit.
@MainActor
struct AppIconCustomPickerRow: View {
    let selectedPath: String
    let onChoose: () -> Void
    let onClear: () -> Void

    private var hasSelection: Bool {
        !selectedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "settings.app.appIcon.custom", defaultValue: "Custom App Icon"))
                    .cmuxFont(size: 13, weight: .medium)
                Text(String(
                    localized: "settings.app.appIcon.custom.subtitle",
                    defaultValue: "Use a local image for the Dock and app switcher. Invalid files fall back to the selected built-in mode."
                ))
                .cmuxFont(.caption)
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Image(systemName: hasSelection ? "photo" : "photo.badge.plus")
                    .foregroundStyle(hasSelection ? .primary : .secondary)
                Text(displayName)
                    .cmuxFont(size: 11)
                    .foregroundStyle(hasSelection ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 150, alignment: .trailing)
                Button(String(localized: "settings.app.appIcon.custom.choose.button", defaultValue: "Choose..."), action: onChoose)
                    .controlSize(.small)
                Button(String(localized: "settings.app.appIcon.custom.clear.button", defaultValue: "Clear"), action: onClear)
                    .controlSize(.small)
                    .disabled(!hasSelection)
            }
            .frame(maxWidth: 360, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CustomAppIconRow")
    }

    private var displayName: String {
        guard hasSelection else {
            return String(
                localized: "settings.app.appIcon.custom.file.none",
                defaultValue: "No file selected"
            )
        }
        return URL(fileURLWithPath: selectedPath).lastPathComponent
    }
}
