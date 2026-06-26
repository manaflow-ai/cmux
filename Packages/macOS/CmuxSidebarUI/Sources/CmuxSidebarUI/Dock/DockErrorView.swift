public import SwiftUI

/// The error placeholder shown in the project Dock when its config fails to load.
///
/// A pure presentation leaf: a warning glyph above a fixed title and the
/// `message` describing the parse/load failure. The title is resolved (and
/// localized) app-side and passed in, so the package view binds to no bundle;
/// the `message` is the already-formatted error string from the store.
public struct DockErrorView: View {
    let title: String
    let message: String

    /// Creates the Dock config-error placeholder.
    /// - Parameters:
    ///   - title: Resolved (already localized) heading shown above the message.
    ///   - message: The error detail string describing the failure.
    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
