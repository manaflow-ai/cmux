public import SwiftUI

/// The browser-data import-hint body: a titled card with a summary, a settings
/// footnote, and a primary import / settings / dismiss button row that collapses
/// to a stacked layout when horizontally constrained.
///
/// Renders from a ``BrowserImportHintSnapshot`` and routes every tap through
/// ``BrowserImportHintActions``. The app-side forwarder builds those values and
/// hosts the placement chrome (toolbar popover, floating card, inline strip) plus
/// the `@State` presentation flags, keeping panel mutations app-side.
public struct BrowserImportHintView: View {
    private let snapshot: BrowserImportHintSnapshot
    private let actions: BrowserImportHintActions

    /// Creates the import-hint body from a snapshot and action bundle.
    public init(snapshot: BrowserImportHintSnapshot, actions: BrowserImportHintActions) {
        self.snapshot = snapshot
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.title)
                .font(.system(size: 12.5, weight: .semibold))

            Text(snapshot.summary)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(snapshot.settingsFootnote)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    primaryButton
                    settingsButton
                    dismissButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    primaryButton
                    HStack(spacing: 10) {
                        settingsButton
                        dismissButton
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var primaryButton: some View {
        Button(snapshot.primaryButtonTitle) {
            actions.onPresentImportFromHint()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("BrowserImportHintImportButton")
    }

    private var settingsButton: some View {
        Button(snapshot.settingsButtonTitle) {
            actions.onOpenImportSettings()
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .accessibilityIdentifier("BrowserImportHintSettingsButton")
    }

    private var dismissButton: some View {
        Button(snapshot.dismissButtonTitle) {
            actions.onDismissImportHint()
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .accessibilityIdentifier("BrowserImportHintDismissButton")
    }
}
