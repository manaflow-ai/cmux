import AppKit
import CMUXMobileCore
import SwiftUI

/// The visual treatments available for the mobile connection page.
///
/// The left-aligned, flat treatment is the product default. The other
/// treatments stay in the same production view so the DEBUG design lab can
/// compare real controls and route states instead of screenshots.
enum MobilePairingDesignVariant: String, CaseIterable, Identifiable, Sendable {
    case focused
    case leading
    case cards
    case list
    case split
    case compact

    var id: String {
        rawValue
    }

    static let defaultsKey = "mobile.pairing.designVariant"
    static let defaultValue: Self = .leading
}

enum MobilePairingTransportChoice: String, Hashable, Sendable {
    case iroh
    case tailscale
}

/// The immutable values and actions shared by each layout treatment.
private struct MobilePairingTransportContext {
    let content: MobilePairingTransportView.Content
    let availableIOSAppTargets: [MobileIOSAppTarget]
    let selectedIOSAppTarget: MobileIOSAppTarget
    let signedInEmail: String?
    let onRefresh: () -> Void
    let onSelectIOSAppTarget: (MobileIOSAppTarget) -> Void
    let copiedValue: String?
    let onCopy: (String) -> Void

    var ready: MobilePairingModel.Ready? {
        guard case let .ready(ready) = content else { return nil }
        return ready
    }

    var reachableViaIroh: Bool {
        switch content {
        case let .ready(ready):
            ready.reachableViaIroh
        case let .needsReachableTransport(reachableViaIroh):
            reachableViaIroh
        }
    }

    var reachableViaTailscale: Bool {
        ready?.reachableViaTailscale == true
    }
}

/// Renders the transport chooser and its pairing presentations.
///
/// Iroh is the account-backed default. Tailscale is an explicit choice for
/// QR or manually-entered host pairing, so the default page never puts a QR
/// code in front of a user who can connect automatically.
struct MobilePairingTransportView: View {
    /// The waiting content to render beneath the transport chooser.
    enum Content: Equatable {
        case ready(MobilePairingModel.Ready)
        case needsReachableTransport(reachableViaIroh: Bool)
    }

    let content: Content
    let availableIOSAppTargets: [MobileIOSAppTarget]
    let selectedIOSAppTarget: MobileIOSAppTarget
    let signedInEmail: String?
    let onRefresh: () -> Void
    let onSelectIOSAppTarget: (MobileIOSAppTarget) -> Void
    let copiedValue: String?
    let onCopy: (String) -> Void
    let design: MobilePairingDesignVariant
    @Binding private var chosenTransport: MobilePairingTransportChoice

    init(
        content: Content,
        availableIOSAppTargets: [MobileIOSAppTarget],
        selectedIOSAppTarget: MobileIOSAppTarget,
        signedInEmail: String?,
        onRefresh: @escaping () -> Void,
        onSelectIOSAppTarget: @escaping (MobileIOSAppTarget) -> Void,
        copiedValue: String?,
        onCopy: @escaping (String) -> Void,
        selection: Binding<MobilePairingTransportChoice>,
        design: MobilePairingDesignVariant = .defaultValue
    ) {
        self.content = content
        self.availableIOSAppTargets = availableIOSAppTargets
        self.selectedIOSAppTarget = selectedIOSAppTarget
        self.signedInEmail = signedInEmail
        self.onRefresh = onRefresh
        self.onSelectIOSAppTarget = onSelectIOSAppTarget
        self.copiedValue = copiedValue
        self.onCopy = onCopy
        _chosenTransport = selection
        self.design = design
    }

    var body: some View {
        Group {
            switch design {
            case .focused:
                MobilePairingFocusedLayout(
                    context: context,
                    selection: $chosenTransport
                )
            case .leading:
                MobilePairingLeadingLayout(
                    context: context,
                    selection: $chosenTransport
                )
            case .cards:
                MobilePairingCardsLayout(
                    context: context,
                    selection: $chosenTransport
                )
            case .list:
                MobilePairingListLayout(
                    context: context,
                    selection: $chosenTransport
                )
            case .split:
                MobilePairingSplitLayout(
                    context: context,
                    selection: $chosenTransport
                )
            case .compact:
                MobilePairingCompactLayout(
                    context: context,
                    selection: $chosenTransport
                )
            }
        }
        .onChange(of: design) { _, _ in chosenTransport = .iroh }
    }

    private var context: MobilePairingTransportContext {
        MobilePairingTransportContext(
            content: content,
            availableIOSAppTargets: availableIOSAppTargets,
            selectedIOSAppTarget: selectedIOSAppTarget,
            signedInEmail: signedInEmail,
            onRefresh: onRefresh,
            onSelectIOSAppTarget: onSelectIOSAppTarget,
            copiedValue: copiedValue,
            onCopy: onCopy
        )
    }
}

private struct MobilePairingFocusedLayout: View {
    let context: MobilePairingTransportContext
    @Binding var selection: MobilePairingTransportChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MobilePairingMethodPicker(selection: $selection, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .center)

            GroupBox {
                MobilePairingMethodContent(
                    context: context,
                    choice: selection,
                    presentation: .focused
                )
                .padding(6)
            }

            MobilePairingAccountFooter(email: context.signedInEmail)
        }
        .frame(maxWidth: 480)
    }
}

/// A left-aligned, flat treatment for users who scan a page from top to bottom.
/// This is the closest match to a calm macOS settings pane: one control, one
/// explanation, one status line.
private struct MobilePairingLeadingLayout: View {
    let context: MobilePairingTransportContext
    @Binding var selection: MobilePairingTransportChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MobilePairingMethodPicker(selection: $selection, alignment: .leading)
                .frame(width: 300, alignment: .leading)

            // Keep the default page on the window surface. The hierarchy is
            // carried by spacing and typography, so a second panel color is
            // not needed.
            MobilePairingMethodContent(
                context: context,
                choice: selection,
                presentation: .leading
            )
            .frame(maxWidth: 540, alignment: .leading)

            MobilePairingAccountFooter(email: context.signedInEmail)
        }
        .frame(maxWidth: 540, alignment: .leading)
    }
}

private struct MobilePairingCardsLayout: View {
    let context: MobilePairingTransportContext
    @Binding var selection: MobilePairingTransportChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MobilePairingMethodPicker(selection: $selection, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(alignment: .top, spacing: 10) {
                MobilePairingChoiceCard(
                    title: String(localized: "mobile.pairing.transport.iroh", defaultValue: "Iroh"),
                    subtitle: String(
                        localized: "mobile.pairing.transport.iroh.shortDetail",
                        defaultValue: "Automatic, no code"
                    ),
                    icon: "lock.shield.fill",
                    isSelected: selection == .iroh,
                    statusColor: context.reachableViaIroh ? .green : .orange
                ) {
                    selection = .iroh
                }

                MobilePairingChoiceCard(
                    title: String(localized: "mobile.pairing.transport.tailscale", defaultValue: "Tailscale"),
                    subtitle: String(
                        localized: "mobile.pairing.transport.tailscale.shortDetail",
                        defaultValue: "QR or manual address"
                    ),
                    icon: "qrcode",
                    isSelected: selection == .tailscale,
                    statusColor: context.reachableViaTailscale ? .green : .secondary
                ) {
                    selection = .tailscale
                }
            }

            GroupBox {
                MobilePairingMethodContent(
                    context: context,
                    choice: selection,
                    presentation: .cards
                )
                .padding(6)
            }

            MobilePairingAccountFooter(email: context.signedInEmail)
        }
        .frame(maxWidth: 520)
    }
}

/// A settings-like treatment that keeps the two transport choices visible as
/// rows while preserving the required segmented control above them.
private struct MobilePairingListLayout: View {
    let context: MobilePairingTransportContext
    @Binding var selection: MobilePairingTransportChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MobilePairingMethodPicker(selection: $selection, alignment: .leading)
                .frame(maxWidth: 300, alignment: .leading)

            VStack(spacing: 0) {
                MobilePairingMethodListRow(
                    title: String(localized: "mobile.pairing.transport.iroh", defaultValue: "Iroh"),
                    detail: String(
                        localized: "mobile.pairing.transport.iroh.shortDetail",
                        defaultValue: "Automatic, no code"
                    ),
                    icon: "lock.shield.fill",
                    isSelected: selection == .iroh,
                    isHealthy: context.reachableViaIroh
                ) {
                    selection = .iroh
                }

                Divider()

                MobilePairingMethodListRow(
                    title: String(localized: "mobile.pairing.transport.tailscale", defaultValue: "Tailscale"),
                    detail: String(
                        localized: "mobile.pairing.transport.tailscale.shortDetail",
                        defaultValue: "QR or manual address"
                    ),
                    icon: "qrcode",
                    isSelected: selection == .tailscale,
                    isHealthy: context.reachableViaTailscale
                ) {
                    selection = .tailscale
                }
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.18))
            )

            GroupBox {
                MobilePairingMethodContent(
                    context: context,
                    choice: selection,
                    presentation: .list
                )
                .padding(10)
            }

            MobilePairingAccountFooter(email: context.signedInEmail)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

private struct MobilePairingSplitLayout: View {
    let context: MobilePairingTransportContext
    @Binding var selection: MobilePairingTransportChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MobilePairingMethodPicker(selection: $selection, alignment: .leading)
                .frame(maxWidth: 300, alignment: .leading)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    MobilePairingSplitChoiceRow(
                        title: String(localized: "mobile.pairing.transport.iroh", defaultValue: "Iroh"),
                        detail: String(
                            localized: "mobile.pairing.transport.iroh.shortDetail",
                            defaultValue: "Automatic, no code"
                        ),
                        icon: "lock.shield.fill",
                        isSelected: selection == .iroh,
                        isHealthy: context.reachableViaIroh
                    ) {
                        selection = .iroh
                    }
                    MobilePairingSplitChoiceRow(
                        title: String(localized: "mobile.pairing.transport.tailscale", defaultValue: "Tailscale"),
                        detail: String(
                            localized: "mobile.pairing.transport.tailscale.shortDetail",
                            defaultValue: "QR or manual address"
                        ),
                        icon: "qrcode",
                        isSelected: selection == .tailscale,
                        isHealthy: context.reachableViaTailscale
                    ) {
                        selection = .tailscale
                    }
                }
                .frame(width: 156, alignment: .leading)

                Divider()

                GroupBox {
                    MobilePairingMethodContent(
                        context: context,
                        choice: selection,
                        presentation: .split
                    )
                    .padding(6)
                }
                .frame(maxWidth: .infinity)
            }

            MobilePairingAccountFooter(email: context.signedInEmail)
        }
        .frame(maxWidth: 680)
    }
}

private struct MobilePairingCompactLayout: View {
    let context: MobilePairingTransportContext
    @Binding var selection: MobilePairingTransportChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MobilePairingMethodPicker(selection: $selection, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .center)
            MobilePairingMethodContent(
                context: context,
                choice: selection,
                presentation: .compact
            )
            MobilePairingAccountFooter(email: context.signedInEmail)
        }
        .frame(maxWidth: 420)
    }
}

private struct MobilePairingMethodPicker: View {
    @Binding var selection: MobilePairingTransportChoice
    let alignment: Alignment

    init(
        selection: Binding<MobilePairingTransportChoice>,
        alignment: Alignment = .center
    ) {
        _selection = selection
        self.alignment = alignment
    }

    var body: some View {
        Picker(
            String(localized: "mobile.pairing.transportPicker", defaultValue: "Connection"),
            selection: $selection
        ) {
            Text(String(localized: "mobile.pairing.transport.iroh", defaultValue: "Iroh"))
                .tag(MobilePairingTransportChoice.iroh)
            Text(String(localized: "mobile.pairing.transport.tailscale", defaultValue: "Tailscale"))
                .tag(MobilePairingTransportChoice.tailscale)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 300, alignment: alignment)
        .accessibilityIdentifier("MobileConnectionTransportPicker")
    }
}

private struct MobilePairingMethodContent: View {
    enum Presentation: Equatable {
        case focused
        case leading
        case cards
        case list
        case split
        case compact

        var isCompact: Bool {
            self == .compact
        }

        var isLeading: Bool {
            switch self {
            case .leading, .list, .split:
                true
            case .focused, .cards, .compact:
                false
            }
        }

        var showsDetailedStatus: Bool {
            self == .split || self == .cards || self == .leading || self == .list
        }
    }

    let context: MobilePairingTransportContext
    let choice: MobilePairingTransportChoice
    let presentation: Presentation

    var body: some View {
        switch choice {
        case .iroh:
            MobilePairingIrohContent(
                reachable: context.reachableViaIroh,
                availableIOSAppTargets: context.availableIOSAppTargets,
                selectedIOSAppTarget: context.selectedIOSAppTarget,
                onRefresh: context.onRefresh,
                onSelectIOSAppTarget: context.onSelectIOSAppTarget,
                presentation: presentation
            )
        case .tailscale:
            MobilePairingTailscaleContent(
                ready: context.ready,
                availableIOSAppTargets: context.availableIOSAppTargets,
                selectedIOSAppTarget: context.selectedIOSAppTarget,
                onRefresh: context.onRefresh,
                onSelectIOSAppTarget: context.onSelectIOSAppTarget,
                copiedValue: context.copiedValue,
                onCopy: context.onCopy,
                presentation: presentation
            )
        }
    }
}

private struct MobilePairingIrohContent: View {
    let reachable: Bool
    let availableIOSAppTargets: [MobileIOSAppTarget]
    let selectedIOSAppTarget: MobileIOSAppTarget
    let onRefresh: () -> Void
    let onSelectIOSAppTarget: (MobileIOSAppTarget) -> Void
    let presentation: MobilePairingMethodContent.Presentation

    var body: some View {
        VStack(
            alignment: presentation.isLeading ? .leading : .center,
            spacing: presentation.isCompact ? 9 : 13
        ) {
            MobilePairingAppBadge(compact: presentation.isCompact)

            Text(String(
                localized: "mobile.pairing.iroh.title",
                defaultValue: "Automatic connection"
            ))
            .cmuxFont(presentation.isCompact ? .headline : .title3, weight: .semibold)

            Text(String(
                localized: "mobile.pairing.irohInstruction",
                defaultValue: "Install cmux on your iPhone and sign in with the same account. It connects automatically. No code needed."
            ))
            .cmuxFont(presentation.isCompact ? .caption : .callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(presentation.isLeading ? .leading : .center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                maxWidth: 430,
                alignment: presentation.isLeading ? .leading : .center
            )

            MobilePairingStatusLine(
                healthy: reachable,
                title: reachable
                    ? String(localized: "mobile.pairing.iroh.status.ready", defaultValue: "Ready to connect")
                    : String(localized: "mobile.pairing.iroh.status.waiting", defaultValue: "Waiting for this Mac")
            )

            if !reachable {
                Button(
                    String(localized: "mobile.pairing.retry", defaultValue: "Try Again"),
                    action: onRefresh
                )
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if availableIOSAppTargets.count > 1 {
                MobilePairingTargetPicker(
                    availableIOSAppTargets: availableIOSAppTargets,
                    selectedIOSAppTarget: selectedIOSAppTarget,
                    onSelect: onSelectIOSAppTarget
                )
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: presentation.isLeading ? .leading : .center
        )
    }
}

private struct MobilePairingTailscaleContent: View {
    let ready: MobilePairingModel.Ready?
    let availableIOSAppTargets: [MobileIOSAppTarget]
    let selectedIOSAppTarget: MobileIOSAppTarget
    let onRefresh: () -> Void
    let onSelectIOSAppTarget: (MobileIOSAppTarget) -> Void
    let copiedValue: String?
    let onCopy: (String) -> Void
    let presentation: MobilePairingMethodContent.Presentation

    var body: some View {
        if let ready, ready.reachableViaTailscale {
            readyContent(ready)
        } else {
            missingContent
        }
    }

    private func readyContent(_ ready: MobilePairingModel.Ready) -> some View {
        VStack(
            alignment: presentation.isLeading ? .leading : .center,
            spacing: presentation.isCompact ? 9 : 13
        ) {
            MobilePairingAppBadge(compact: presentation.isCompact)

            MobilePairingQRImageView(payload: ready.attachURL)
                .frame(
                    maxWidth: presentation.isCompact ? 240 : 320,
                    alignment: presentation.isLeading ? .leading : .center
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2))
                )

            HStack(spacing: 10) {
                MobilePairingWaitingIndicator(compact: presentation.isCompact)
                Button(
                    String(localized: "mobile.pairing.refresh", defaultValue: "Refresh Code"),
                    action: onRefresh
                )
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("MobilePairingRefreshCodeButton")
            }

            Text(String(
                localized: "mobile.pairing.scanInstruction",
                defaultValue: "In cmux on your iPhone, sign in with the same account, choose Tailscale, then scan this code."
            ))
            .cmuxFont(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(presentation.isLeading ? .leading : .center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                maxWidth: 430,
                alignment: presentation.isLeading ? .leading : .center
            )

            if availableIOSAppTargets.count > 1 {
                MobilePairingTargetPicker(
                    availableIOSAppTargets: availableIOSAppTargets,
                    selectedIOSAppTarget: selectedIOSAppTarget,
                    onSelect: onSelectIOSAppTarget
                )
            }

            MobilePairingManualEntry(
                ready: ready,
                expanded: presentation.showsDetailedStatus,
                copiedValue: copiedValue,
                onCopy: onCopy
            )
        }
        .frame(
            maxWidth: .infinity,
            alignment: presentation.isLeading ? .leading : .center
        )
    }

    private var missingContent: some View {
        VStack(
            alignment: presentation.isLeading ? .leading : .center,
            spacing: 10
        ) {
            MobilePairingAppBadge(compact: presentation.isCompact)
            Image(systemName: "network.slash")
                .cmuxFont(size: presentation.isCompact ? 26 : 32)
                .foregroundStyle(.orange)
            Text(String(
                localized: "mobile.pairing.req.tailscale.missing",
                defaultValue: "Tailscale is not connected on this Mac. Install it on both devices and connect both to the same Tailscale network."
            ))
            .cmuxFont(presentation.isCompact ? .caption : .callout)
            .multilineTextAlignment(presentation.isLeading ? .leading : .center)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Link(
                String(localized: "mobile.pairing.req.tailscale.get", defaultValue: "Get Tailscale"),
                destination: URL(string: "https://tailscale.com/download")!
            )
            .buttonStyle(.borderedProminent)
            Button(
                String(localized: "mobile.pairing.retry", defaultValue: "Try Again"),
                action: onRefresh
            )
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(
            maxWidth: .infinity,
            alignment: presentation.isLeading ? .leading : .center
        )
    }
}

private struct MobilePairingChoiceCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let isSelected: Bool
    let statusColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Spacer(minLength: 4)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                }
                Text(title)
                    .cmuxFont(.callout, weight: .semibold)
                Text(subtitle)
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.12)
                    : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.18),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct MobilePairingMethodListRow: View {
    let title: String
    let detail: String
    let icon: String
    let isSelected: Bool
    let isHealthy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title).cmuxFont(.callout, weight: .medium)
                    Text(detail)
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Circle()
                    .fill(isHealthy ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)

                if isSelected {
                    Image(systemName: "checkmark")
                        .cmuxFont(.caption, weight: .semibold)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 14)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

private struct MobilePairingSplitChoiceRow: View {
    let title: String
    let detail: String
    let icon: String
    let isSelected: Bool
    let isHealthy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).cmuxFont(.callout, weight: .medium)
                    Text(detail)
                        .cmuxFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                Circle()
                    .fill(isHealthy ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct MobilePairingStatusLine: View {
    let healthy: Bool
    let title: String

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(healthy ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(title)
                .cmuxFont(.caption, weight: .medium)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MobilePairingWaitingIndicator: View {
    let compact: Bool

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(String(localized: "mobile.pairing.waiting", defaultValue: "Waiting for your iPhone…"))
                .cmuxFont(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MobilePairingTargetPicker: View {
    let availableIOSAppTargets: [MobileIOSAppTarget]
    let selectedIOSAppTarget: MobileIOSAppTarget
    let onSelect: (MobileIOSAppTarget) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(String(localized: "mobile.pairing.targetApp", defaultValue: "Open with"))
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
            Picker(
                String(localized: "mobile.pairing.targetApp", defaultValue: "Open with"),
                selection: Binding(
                    get: { selectedIOSAppTarget },
                    set: onSelect
                )
            ) {
                ForEach(availableIOSAppTargets) { target in
                    Text(target.displayName).tag(target)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }
}

private struct MobilePairingManualEntry: View {
    let ready: MobilePairingModel.Ready
    let expanded: Bool
    let copiedValue: String?
    let onCopy: (String) -> Void

    @State private var isExpanded: Bool

    init(
        ready: MobilePairingModel.Ready,
        expanded: Bool,
        copiedValue: String?,
        onCopy: @escaping (String) -> Void
    ) {
        self.ready = ready
        self.expanded = expanded
        self.copiedValue = copiedValue
        self.onCopy = onCopy
        _isExpanded = State(initialValue: expanded)
    }

    var body: some View {
        if let entry = ready.manualEntry, !ready.tailscaleLines.isEmpty {
            DisclosureGroup(
                isExpanded: $isExpanded,
                content: {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ready.tailscaleLines, id: \.self) { line in
                            Text(line)
                                .cmuxFont(.caption, design: .monospaced)
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            MobilePairingCopyButton(
                                label: String(localized: "mobile.pairing.manual.copyIP", defaultValue: "Copy IP"),
                                value: entry.host,
                                copiedValue: copiedValue,
                                onCopy: onCopy
                            )
                            MobilePairingCopyButton(
                                label: String(localized: "mobile.pairing.manual.copyPort", defaultValue: "Copy Port"),
                                value: String(entry.port),
                                copiedValue: copiedValue,
                                onCopy: onCopy
                            )
                        }
                    }
                    .padding(.top, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                },
                label: {
                    Text(String(
                        localized: "mobile.pairing.manual.addTitle",
                        defaultValue: "Can't scan? Add this Mac manually"
                    ))
                    .cmuxFont(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)
                }
            )
            .frame(maxWidth: 460, alignment: .leading)
        }
    }
}

private struct MobilePairingCopyButton: View {
    let label: String
    let value: String
    let copiedValue: String?
    let onCopy: (String) -> Void

    var body: some View {
        Button {
            guard GhosttyApp.terminalPasteboard.writeString(value, to: .general) else { return }
            onCopy(value)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copiedValue == value ? "checkmark" : "doc.on.doc")
                Text(copiedValue == value
                    ? String(localized: "mobile.pairing.manual.copied", defaultValue: "Copied")
                    : label)
            }
            .cmuxFont(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private struct MobilePairingAppBadge: View {
    let compact: Bool

    var body: some View {
        Link(
            destination: URL(string: "https://github.com/manaflow-ai/cmux#founders-edition")!
        ) {
            HStack(spacing: compact ? 6 : 8) {
                Image(systemName: "apple.logo")
                    .cmuxFont(size: compact ? 16 : 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(String(
                        localized: "mobile.pairing.getApp.badge.caption",
                        defaultValue: "Download cmux for"
                    ))
                    .cmuxFont(.caption2)
                    Text(String(
                        localized: "mobile.pairing.getApp.badge.platform",
                        defaultValue: "iPhone"
                    ))
                    .cmuxFont(compact ? .callout : .title3, weight: .semibold)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 4 : 6)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.3))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(
            localized: "mobile.pairing.getApp.link",
            defaultValue: "Get cmux for iPhone"
        ))
    }
}

private struct MobilePairingAccountFooter: View {
    let email: String?

    var body: some View {
        if let email {
            HStack {
                Text(String(
                    format: String(localized: "mobile.pairing.signedInAs", defaultValue: "Signed in as %@"),
                    locale: .current,
                    email
                ))
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                Spacer()
            }
        }
    }
}
