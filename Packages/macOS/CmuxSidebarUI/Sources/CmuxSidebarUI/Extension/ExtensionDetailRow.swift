public import SwiftUI

/// A label/value row used in the extension details popover and access-review
/// sheet (status, bundle identifier, configuration).
///
/// A pure presentation leaf: it holds no app-target state and performs no work.
/// The already-localized `title` and the `value` are passed in as plain strings.
public struct ExtensionDetailRow: View {
    let title: String
    let value: String

    /// Creates an extension detail row.
    /// - Parameters:
    ///   - title: The resolved (already localized) row label.
    ///   - value: The row value (bundle id, configuration string, status text).
    public init(title: String, value: String) {
        self.title = title
        self.value = value
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}
