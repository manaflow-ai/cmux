#if os(iOS)
import CmuxMobileSupport
import CmuxMobileWorkspace
import SwiftUI

/// Re-enterable setup help that makes every pre-pairing dead-end explicit, so
/// none of them is a silent blank add-device screen.
///
/// It is presented two ways:
/// - From Settings ("Set up your Mac"), where it is a reference the user can open
///   any time.
/// - From the onboarding flow and the disconnected screen ("Need help
///   connecting?"), where a stuck user reaches it without first pairing.
///
/// The view is pairing-ignorant: it never starts a connect attempt and never
/// inspects an in-flight pairing. It only reads durable signals (signed in,
/// known paired Mac) to pick which gate to highlight, and renders static
/// guidance for each of the four setup gates classified by
/// ``MobileSetupGuidancePolicy``. The honest network section states the real
/// constraint: QR pairing needs Tailscale on the Mac, and same-Wi-Fi without
/// Tailscale only works by typing the Mac's local address by hand over an
/// unencrypted link.
struct SetupHelpView: View {
    /// The gate to emphasize, or `nil` when the user has no current blocker (for
    /// example Settings opened while connected). When set, that gate floats to the
    /// top with a "You are here" marker; the other gates still render so the whole
    /// path stays visible. When `nil`, the screen is a plain reference with no
    /// marker, in setup order.
    let highlight: MobileSetupGuidanceState?
    /// Optional dismiss for sheet presentation. `nil` when pushed onto a stack.
    let onDone: (() -> Void)?

    /// Tailscale install page (App Store entry plus per-platform downloads). Used
    /// for both the phone and the Mac since the page links every platform.
    private static let tailscaleURL = URL(string: "https://tailscale.com/download")!
    /// Tailscale on the App Store, for the phone-side install step.
    private static let tailscaleAppStoreURL = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!
    /// Founders Edition page: cmux for Mac download plus TestFlight enrollment.
    private static let macDownloadURL = URL(string: "https://github.com/manaflow-ai/cmux#founders-edition")!

    var body: some View {
        NavigationStack {
            Form {
                introSection
                ForEach(orderedGates, id: \.self) { gate in
                    gateSection(gate)
                }
                networkSection
            }
            .navigationTitle(L10n.string("mobile.setupHelp.title", defaultValue: "Set up your Mac"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("mobile.settings.done", defaultValue: "Done"), action: onDone)
                            .accessibilityIdentifier("MobileSetupHelpDone")
                    }
                }
            }
            .accessibilityIdentifier("MobileSetupHelpView")
        }
    }

    /// All four gates in setup order. When a blocker is highlighted it floats to
    /// the top so the user sees their next step first without losing the full
    /// path; with no blocker the natural setup order is kept.
    private var orderedGates: [MobileSetupGuidanceState] {
        let order: [MobileSetupGuidanceState] = [
            .notSignedIn, .signedInNeverPaired, .macUnreachable, .accountMismatch,
        ]
        guard let highlight else { return order }
        return [highlight] + order.filter { $0 != highlight }
    }

    private var introSection: some View {
        Section {
            Text(highlight == nil
                ? L10n.string(
                    "mobile.setupHelp.introReference",
                    defaultValue: "To see your Mac's terminals here, four things have to line up."
                )
                : L10n.string(
                    "mobile.setupHelp.intro",
                    defaultValue: "To see your Mac's terminals here, four things have to line up. The step you are on is marked below."
                ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func gateSection(_ gate: MobileSetupGuidanceState) -> some View {
        let content = Self.content(for: gate)
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(content.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let link = content.link {
                    Link(destination: link.url) {
                        Label(link.title, systemImage: "arrow.up.right.square")
                            .font(.callout.weight(.medium))
                    }
                    .accessibilityIdentifier(content.linkAccessibilityIdentifier)
                }
            }
            .padding(.vertical, 2)
        } header: {
            HStack(spacing: 8) {
                Image(systemName: content.systemImage)
                    .foregroundStyle(.tint)
                Text(content.title)
                if gate == highlight {
                    Spacer(minLength: 8)
                    Text(L10n.string("mobile.setupHelp.youAreHere", defaultValue: "You are here"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityIdentifier("MobileSetupHelpYouAreHere")
                }
            }
        }
        .accessibilityIdentifier("MobileSetupHelpGate.\(content.identifierSuffix)")
    }

    private var networkSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string(
                    "mobile.setupHelp.networkBody",
                    defaultValue: "Scanning the Mac's QR code needs Tailscale: the Mac only shows a code when it has a Tailscale address your phone can reach. Install Tailscale on both, sign both in to the same tailnet, and the code appears."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Link(destination: Self.tailscaleAppStoreURL) {
                    Label(
                        L10n.string("mobile.setupHelp.tailscaleAppStore", defaultValue: "Get Tailscale for iPhone"),
                        systemImage: "arrow.up.right.square"
                    )
                    .font(.callout.weight(.medium))
                }
                .accessibilityIdentifier("MobileSetupHelpTailscaleAppStoreLink")

                Link(destination: Self.tailscaleURL) {
                    Label(
                        L10n.string("mobile.setupHelp.tailscaleMac", defaultValue: "Set up Tailscale on the Mac"),
                        systemImage: "arrow.up.right.square"
                    )
                    .font(.callout.weight(.medium))
                }
                .accessibilityIdentifier("MobileSetupHelpTailscaleMacLink")

                Text(L10n.string(
                    "mobile.setupHelp.lanBody",
                    defaultValue: "No Tailscale? On the same Wi-Fi you can still connect by typing the Mac's local address and port by hand in Add device. That link is unencrypted, so only use it on a network you trust."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }
            .padding(.vertical, 2)
        } header: {
            HStack(spacing: 8) {
                Image(systemName: "lock.laptopcomputer")
                    .foregroundStyle(.tint)
                Text(L10n.string("mobile.setupHelp.networkTitle", defaultValue: "Get them on the same network"))
            }
        } footer: {
            Text(L10n.string(
                "mobile.setupHelp.sameAccountFooter",
                defaultValue: "The Mac and this phone must be signed in to the same cmux account, and on the same tailnet (or the same Wi-Fi for a manual local connection)."
            ))
        }
        .accessibilityIdentifier("MobileSetupHelpNetworkSection")
    }

    // MARK: - Gate content

    /// The static guidance shown for one setup gate.
    private struct GateContent {
        let systemImage: String
        let title: String
        let body: String
        let link: GateLink?
        let identifierSuffix: String
        let linkAccessibilityIdentifier: String
    }

    private struct GateLink {
        let title: String
        let url: URL
    }

    private static func content(for gate: MobileSetupGuidanceState) -> GateContent {
        switch gate {
        case .notSignedIn:
            return GateContent(
                systemImage: "person.crop.circle",
                title: L10n.string("mobile.setupHelp.signInTitle", defaultValue: "Sign in"),
                body: L10n.string(
                    "mobile.setupHelp.signInBody",
                    defaultValue: "Sign in to cmux on this phone with the same account your Mac uses. Without that, there is nothing to connect to."
                ),
                link: nil,
                identifierSuffix: "notSignedIn",
                linkAccessibilityIdentifier: "MobileSetupHelpSignInLink"
            )
        case .signedInNeverPaired:
            return GateContent(
                systemImage: "desktopcomputer",
                title: L10n.string("mobile.setupHelp.macAppTitle", defaultValue: "Run cmux on your Mac"),
                body: L10n.string(
                    "mobile.setupHelp.macAppBody",
                    defaultValue: "Install the cmux Mac app and leave it running, signed in to the same account. The phone pairs to a running Mac, so a quit or never-installed app is the most common reason pairing does nothing."
                ),
                link: GateLink(
                    title: L10n.string("mobile.setupHelp.macAppLink", defaultValue: "Download cmux for Mac"),
                    url: macDownloadURL
                ),
                identifierSuffix: "signedInNeverPaired",
                linkAccessibilityIdentifier: "MobileSetupHelpMacAppLink"
            )
        case .macUnreachable:
            return GateContent(
                systemImage: "wifi.exclamationmark",
                title: L10n.string("mobile.setupHelp.unreachableTitle", defaultValue: "Wake the Mac"),
                body: L10n.string(
                    "mobile.setupHelp.unreachableBody",
                    defaultValue: "You have paired this Mac before but it is not reachable now. Wake it, make sure cmux is running, and confirm both devices are on the same tailnet or Wi-Fi. Then reconnect."
                ),
                link: nil,
                identifierSuffix: "macUnreachable",
                linkAccessibilityIdentifier: "MobileSetupHelpUnreachableLink"
            )
        case .accountMismatch:
            return GateContent(
                systemImage: "person.crop.circle.badge.exclamationmark",
                title: L10n.string("mobile.setupHelp.mismatchTitle", defaultValue: "Match the account"),
                body: L10n.string(
                    "mobile.setupHelp.mismatchBody",
                    defaultValue: "If pairing is refused for a different account, this phone and the Mac are on different cmux accounts. Sign this phone in to the Mac's account, or sign the Mac in to this one, then pair again."
                ),
                link: nil,
                identifierSuffix: "accountMismatch",
                linkAccessibilityIdentifier: "MobileSetupHelpMismatchLink"
            )
        }
    }
}
#endif
