import SwiftUI

/// Small caption-style note rendered inside a ``SettingsCard`` —
/// typically used after a row to explain a setting's effect in
/// secondary-colored text. Mirrors the legacy in-app chrome.
@MainActor
public struct SettingsCardNote: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
