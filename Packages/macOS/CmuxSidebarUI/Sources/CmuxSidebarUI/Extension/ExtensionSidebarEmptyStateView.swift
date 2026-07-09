public import ExtensionFoundation
public import SwiftUI

/// The empty/chooser state shown when no sidebar extension is hosted: the
/// placeholder glyph, the title/detail copy, the availability note, and the
/// chooser / manage / use-default actions.
///
/// A pure presentation leaf. It holds no app-target state: the app passes the
/// enabled identities snapshot plus the live availability counts as values, the
/// already-localized copy via ``ExtensionSidebarEmptyStateStrings``, and the
/// selection / manage / use-default behaviors as closures (those reach app-only
/// state — the selection model, the extension browser, `NSApp` — and stay in the
/// app target). The title/detail/availability selection logic that branches on
/// the counts lives here; `String(localized:)` stays app-side.
public struct ExtensionSidebarEmptyStateView: View {
    private let enabledIdentities: [AppExtensionIdentity]
    private let errorText: String?
    private let disabledExtensionCount: Int
    private let unapprovedExtensionCount: Int
    private let strings: ExtensionSidebarEmptyStateStrings
    private let onSelect: (AppExtensionIdentity) -> Void
    private let onManage: () -> Void
    private let onUseDefault: () -> Void

    /// Creates the empty/chooser state view.
    /// - Parameters:
    ///   - enabledIdentities: The deduplicated, name-sorted enabled identities.
    ///   - errorText: An XPC/discovery error to surface instead of the detail copy.
    ///   - disabledExtensionCount: Count of installed-but-disabled extensions.
    ///   - unapprovedExtensionCount: Count of installed-but-unapproved extensions.
    ///   - strings: App-resolved localized copy.
    ///   - onSelect: Selects an enabled identity to host.
    ///   - onManage: Opens the sidebar-extension browser.
    ///   - onUseDefault: Switches back to the default sidebar.
    public init(
        enabledIdentities: [AppExtensionIdentity],
        errorText: String?,
        disabledExtensionCount: Int,
        unapprovedExtensionCount: Int,
        strings: ExtensionSidebarEmptyStateStrings,
        onSelect: @escaping (AppExtensionIdentity) -> Void,
        onManage: @escaping () -> Void,
        onUseDefault: @escaping () -> Void
    ) {
        self.enabledIdentities = enabledIdentities
        self.errorText = errorText
        self.disabledExtensionCount = disabledExtensionCount
        self.unapprovedExtensionCount = unapprovedExtensionCount
        self.strings = strings
        self.onSelect = onSelect
        self.onManage = onManage
        self.onUseDefault = onUseDefault
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 60, height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                )
            VStack(spacing: 6) {
                Text(emptyStateTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                Text(errorText ?? emptyStateDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if disabledExtensionCount > 0 || unapprovedExtensionCount > 0 {
                    Text(extensionAvailabilityDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            extensionEmptyActions()
                .padding(.top, 2)
        }
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(24)
        .accessibilityIdentifier("CMUXExtensionSidebarEmptyState")
    }

    private var emptyStateTitle: String {
        if enabledIdentities.count > 1 {
            return strings.chooseTitle
        }
        return strings.emptyTitle
    }

    private var emptyStateDetail: String {
        if enabledIdentities.count > 1 {
            return strings.chooseDetail
        }
        return strings.emptyDetail
    }

    private var extensionAvailabilityDetail: String {
        if unapprovedExtensionCount > 0 {
            return strings.unapprovedDetail
        }
        return strings.disabledDetail
    }

    @ViewBuilder
    private func extensionEmptyActions() -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                extensionEmptyActionButtons()
            }
            VStack(spacing: 8) {
                extensionEmptyActionButtons()
            }
        }
    }

    @ViewBuilder
    private func extensionEmptyActionButtons() -> some View {
        if enabledIdentities.count > 1 {
            Menu {
                ForEach(enabledIdentities, id: \.bundleIdentifier) { enabledIdentity in
                    Button {
                        onSelect(enabledIdentity)
                    } label: {
                        Label(enabledIdentity.localizedName, systemImage: "puzzlepiece.extension")
                    }
                }
            } label: {
                Label(strings.chooseAction, systemImage: "puzzlepiece.extension")
            }
            .menuStyle(.button)
            .controlSize(.small)
        }

        Button {
            onManage()
        } label: {
            Label(strings.manage, systemImage: "puzzlepiece.extension")
        }
        .controlSize(.small)

        Button {
            onUseDefault()
        } label: {
            Label(strings.useDefault, systemImage: "sidebar.left")
        }
        .controlSize(.small)
    }
}
