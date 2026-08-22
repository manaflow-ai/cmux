#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// One release note: the unit both the one-time what's-new sheet and the
/// Settings archive render. New releases append entries to
/// ``MobileWhatsNewCatalog/entries`` (newest first) so past notices stay
/// findable after their one-time sheet was dismissed.
struct MobileWhatsNewEntry: Identifiable {
    struct Feature {
        let symbol: String
        let title: String
        let detail: String
    }

    let id: String
    /// Human-readable release label shown in the archive list ("0.64 · August 2026").
    let releaseLabel: String
    let title: String
    let features: [Feature]
}

enum MobileWhatsNewCatalog {
    /// Newest first. The first entry is the one the one-time sheet shows.
    static var entries: [MobileWhatsNewEntry] {
        [connectionsUpdate]
    }

    static var connectionsUpdate: MobileWhatsNewEntry {
        MobileWhatsNewEntry(
            id: "connections.v1",
            releaseLabel: L10n.string(
                "mobile.connectionsUpdate.releaseLabel",
                defaultValue: "0.64 · August 2026"
            ),
            title: L10n.string(
                "mobile.connectionsUpdate.title",
                defaultValue: "What's New in cmux"
            ),
            features: [
                .init(
                    symbol: "desktopcomputer.and.macbook",
                    title: L10n.string(
                        "mobile.connectionsUpdate.perComputer.title",
                        defaultValue: "Per-computer methods"
                    ),
                    detail: L10n.string(
                        "mobile.connectionsUpdate.perComputer.detail",
                        defaultValue: "Each computer now picks how this iPhone reaches it: Iroh, Tailscale Only, or Direct. Set it in Computers → your computer → Connection Method."
                    )
                ),
                .init(
                    symbol: "bolt.horizontal",
                    title: L10n.string(
                        "mobile.connectionsUpdate.iroh.title",
                        defaultValue: "Auto-Connect is now Iroh"
                    ),
                    detail: L10n.string(
                        "mobile.connectionsUpdate.iroh.detail",
                        defaultValue: "Same authenticated, end-to-end encrypted connection — clearer name. The app-wide setting moved out of Settings."
                    )
                ),
                .init(
                    symbol: "network",
                    title: L10n.string(
                        "mobile.connectionsUpdate.direct.title",
                        defaultValue: "New: Direct addresses"
                    ),
                    detail: L10n.string(
                        "mobile.connectionsUpdate.direct.detail",
                        defaultValue: "On your LAN, WireGuard, or any other network: add the addresses where a computer is reachable and dial exactly those — no fallback."
                    )
                ),
                .init(
                    symbol: "qrcode.viewfinder",
                    title: L10n.string(
                        "mobile.connectionsUpdate.tailscale.title",
                        defaultValue: "Tailscale, on your terms"
                    ),
                    detail: L10n.string(
                        "mobile.connectionsUpdate.tailscale.detail",
                        defaultValue: "Choosing Tailscale Only shows exactly what's missing and offers the pairing-code scan right there — nothing opens on its own."
                    )
                ),
            ]
        )
    }
}

/// The shared title + feature-row layout, HIG What's New template shape.
struct MobileWhatsNewContent: View {
    let entry: MobileWhatsNewEntry

    var body: some View {
        VStack(spacing: 36) {
            Text(entry.title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .padding(.top, 56)
                .padding(.horizontal, 32)
            VStack(alignment: .leading, spacing: 28) {
                ForEach(entry.features, id: \.title) { feature in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: feature.symbol)
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 40)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .font(.headline)
                            Text(feature.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }
}

/// One-time "what's new" sheet for the latest release, shown on first launch
/// after updating for users who already have Computers (fresh installs learn
/// the same things in onboarding). Every notice stays readable later in
/// Settings → What's New.
struct MobileConnectionsUpdateSheet: View {
    /// Defaults key marking the notice as acknowledged on this device.
    static let acknowledgedKey = "dev.cmux.mobile.connectionsUpdateNotice.v1"

    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                MobileWhatsNewContent(entry: MobileWhatsNewCatalog.connectionsUpdate)
            }
            Button(action: dismiss) {
                Text(L10n.string(
                    "mobile.connectionsUpdate.cta",
                    defaultValue: "Continue"
                ))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.blue)
            .accessibilityIdentifier("MobileConnectionsUpdateGotIt")
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(PlatformPalette.systemBackground)
        .accessibilityIdentifier("MobileConnectionsUpdateSheet")
    }
}

/// Settings → What's New: every release notice over time, newest first.
struct MobileWhatsNewListView: View {
    var body: some View {
        List {
            ForEach(MobileWhatsNewCatalog.entries) { entry in
                NavigationLink {
                    ScrollView {
                        MobileWhatsNewContent(entry: entry)
                    }
                    .background(PlatformPalette.systemBackground)
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                        Text(entry.releaseLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("MobileWhatsNewEntry-\(entry.id)")
            }
        }
        .navigationTitle(L10n.string(
            "mobile.settings.whatsNew",
            defaultValue: "What's New"
        ))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("MobileWhatsNewList")
    }
}
#endif
