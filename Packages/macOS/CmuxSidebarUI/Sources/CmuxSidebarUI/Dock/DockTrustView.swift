public import SwiftUI

/// The trust prompt shown in the project Dock before its config commands run.
///
/// A pure presentation leaf: a shield glyph above a title, an explanatory
/// message, the monospaced `configPath`, and a "trust and start" button. All
/// copy is resolved (and localized) app-side and passed in, so the package view
/// binds to no bundle; `onTrust` is invoked when the user accepts the prompt.
public struct DockTrustView: View {
    let configPath: String
    let title: String
    let message: String
    let actionTitle: String
    let onTrust: () -> Void

    /// Creates the project-Dock trust prompt.
    /// - Parameters:
    ///   - configPath: The Dock config file path shown in monospace.
    ///   - title: Resolved (already localized) heading for the prompt.
    ///   - message: Resolved (already localized) explanatory body text.
    ///   - actionTitle: Resolved (already localized) title for the trust button.
    ///   - onTrust: Invoked when the user taps the trust button.
    public init(
        configPath: String,
        title: String,
        message: String,
        actionTitle: String,
        onTrust: @escaping () -> Void
    ) {
        self.configPath = configPath
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.onTrust = onTrust
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Text(configPath)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Button(actionTitle) {
                onTrust()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
