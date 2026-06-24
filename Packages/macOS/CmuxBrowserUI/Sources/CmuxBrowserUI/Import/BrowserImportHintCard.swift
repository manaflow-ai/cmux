public import SwiftUI

/// The empty-state import-hint card shown when a browser panel is on the new-tab
/// page and has no imported data yet.
///
/// This is the SwiftUI presentation only. The hint's variant/placement decision
/// (`BrowserImportHintPresentation`) and the summary text live with the panel that
/// hosts the card. The three action buttons (import, open settings, dismiss) hand
/// their taps back to injected closures so the side effects stay app-side:
/// `onImport` drives `BrowserDataImportCoordinator`, `onOpenSettings` opens the
/// app Settings window, and `onDismiss` clears the blank-tab preference.
///
/// `BrowserImportHintCardStyle` selects the chrome the body is wrapped in so the
/// floating card, inline strip, and toolbar-chip popover share one body.
public struct BrowserImportHintCard: View {
    /// The chrome the hint body is wrapped in for each placement.
    public enum Style: Sendable {
        /// Centered floating card overlay over the blank-tab page.
        case floatingCard
        /// Leading inline strip pinned near the top of the blank-tab page.
        case inlineStrip
        /// Compact body presented inside the toolbar chip's popover.
        case popover
    }

    private let summary: String
    private let style: Style
    private let onImport: () -> Void
    private let onOpenSettings: () -> Void
    private let onDismiss: () -> Void

    /// Creates an import-hint card.
    /// - Parameters:
    ///   - summary: The localized one-line description of detected browsers.
    ///   - style: The chrome to wrap the hint body in.
    ///   - onImport: Invoked when the primary "Import…" button is tapped.
    ///   - onOpenSettings: Invoked when the "Browser Settings" button is tapped.
    ///   - onDismiss: Invoked when the "Hide Hint" button is tapped.
    public init(
        summary: String,
        style: Style,
        onImport: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.summary = summary
        self.style = style
        self.onImport = onImport
        self.onOpenSettings = onOpenSettings
        self.onDismiss = onDismiss
    }

    public var body: some View {
        switch style {
        case .floatingCard:
            floatingCard
        case .inlineStrip:
            inlineStrip
        case .popover:
            popover
        }
    }

    private var floatingCard: some View {
        VStack {
            Spacer(minLength: 22)

            hintBody
            .padding(12)
            .frame(maxWidth: 360, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(
                    Color(nsColor: .separatorColor).opacity(0.45),
                    lineWidth: 1
                )
            )
            .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)

            Spacer()
        }
        .padding(.horizontal, 18)
    }

    private var inlineStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            hintBody
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: 520, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.84))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(
                        Color(nsColor: .separatorColor).opacity(0.35),
                        lineWidth: 1
                    )
                )
                .shadow(color: Color.black.opacity(0.05), radius: 6, y: 2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private var popover: some View {
        hintBody
            .padding(12)
            .frame(width: 300, alignment: .leading)
    }

    private var hintBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "browser.import.hint.title", defaultValue: "Import browser data", bundle: .module))
                .font(.system(size: 12.5, weight: .semibold))

            Text(summary)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(String(localized: "browser.import.hint.settingsFootnote", defaultValue: "You can always find this in Settings > Browser.", bundle: .module))
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
        Button(String(localized: "browser.import.hint.import", defaultValue: "Import…", bundle: .module)) {
            onImport()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("BrowserImportHintImportButton")
    }

    private var settingsButton: some View {
        Button(String(localized: "browser.import.hint.settings", defaultValue: "Browser Settings", bundle: .module)) {
            onOpenSettings()
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .accessibilityIdentifier("BrowserImportHintSettingsButton")
    }

    private var dismissButton: some View {
        Button(String(localized: "browser.import.hint.dismiss", defaultValue: "Hide Hint", bundle: .module)) {
            onDismiss()
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .accessibilityIdentifier("BrowserImportHintDismissButton")
    }
}
