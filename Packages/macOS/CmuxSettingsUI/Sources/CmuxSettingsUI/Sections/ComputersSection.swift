import CmuxFoundation
import SwiftUI

/// **Computers** section — the account's registered computers (from the team
/// device registry) with live presence, plus Mac-to-Mac pairing: pair a
/// listed computer in one click, paste a pairing link from another Mac, or
/// show this Mac's own pairing code.
@MainActor
public struct ComputersSection: View {
    @State private var model: ComputersListModel
    /// Device ids with a pair/unpair action in flight, so their buttons show
    /// a busy state without re-rendering unrelated rows.
    @State private var pendingDeviceIDs: Set<String> = []
    /// The pasted pairing-link draft.
    @State private var pairingLink: String = ""
    /// Result of the most recent pair action, shown inline under the link row.
    @State private var pairResult: ComputersPairResult?
    /// Guards overlapping link-pair submissions.
    @State private var isPairingLink = false
    /// Result of the most recent copy-link action, shown under its row.
    @State private var copyLinkResult: ComputersCopyLinkResult?
    /// Guards overlapping copy-link mints.
    @State private var isCopyingLink = false

    private let hostActions: SettingsHostActions

    /// Creates the Computers section bound to the host bridge.
    /// - Parameter hostActions: Supplies the merged computer snapshots and
    ///   the pair/unpair/refresh actions.
    public init(hostActions: SettingsHostActions) {
        _model = State(initialValue: ComputersListModel(hostActions: hostActions))
        self.hostActions = hostActions
    }

    /// The Computers section content.
    public var body: some View {
        Group {
            SettingsSectionHeader(
                String(localized: "settings.section.computers", defaultValue: "Computers"),
                section: .computers
            )
            SettingsCard {
                if let snapshot = model.current, snapshot.isSignedIn {
                    computerRows(snapshot)
                    SettingsCardDivider()
                } else {
                    SettingsCardNote(String(
                        localized: "settings.computers.signedOut",
                        defaultValue: "Sign in to see and pair the computers on your account."
                    ))
                    SettingsCardDivider()
                }
                pairingLinkRow
                pairResultCaption
                SettingsCardDivider()
                pairThisMacRow
                copyLinkResultCaption
            }
        }
        .task {
            startSettingsObservation([model])
            hostActions.refreshComputers()
        }
    }

    @ViewBuilder
    private func computerRows(_ snapshot: ComputersSettingsSnapshot) -> some View {
        if snapshot.computers.isEmpty {
            SettingsCardNote(String(
                localized: "settings.computers.empty",
                defaultValue: "No computers registered yet. Open cmux on another device signed in to the same account."
            ))
        } else {
            ForEach(snapshot.computers) { computer in
                ComputersSectionRow(
                    computer: computer,
                    isPending: pendingDeviceIDs.contains(computer.deviceID),
                    pair: { pair(deviceID: computer.deviceID) },
                    unpair: { unpair(deviceID: computer.deviceID) }
                )
            }
        }
        if snapshot.lastRefreshFailed {
            SettingsCardNote(String(
                localized: "settings.computers.refreshFailed",
                defaultValue: "Couldn't reach the device registry. Showing locally known computers."
            ))
        }
        refreshRow
    }

    @ViewBuilder
    private var refreshRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:computers:refresh",
            String(localized: "settings.computers.refresh", defaultValue: "Refresh List"),
            subtitle: String(
                localized: "settings.computers.refresh.subtitle",
                defaultValue: "Fetch the account's registered computers again."
            )
        ) {
            Button(String(localized: "settings.computers.refresh.button", defaultValue: "Refresh")) {
                hostActions.refreshComputers()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("SettingsComputersRefreshButton")
        }
    }

    @ViewBuilder
    private var pairingLinkRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:computers:pairingLink",
            String(localized: "settings.computers.pairingLink", defaultValue: "Add by Pairing Link"),
            subtitle: String(
                localized: "settings.computers.pairingLink.subtitle",
                defaultValue: "Paste the pairing link from the other Mac's pairing window (the QR code's contents)."
            ),
            controlWidth: 260
        ) {
            HStack(spacing: 8) {
                TextField(
                    String(localized: "settings.computers.pairingLink.placeholder", defaultValue: "cmux-ios://attach?…"),
                    text: $pairingLink
                )
                .textFieldStyle(.roundedBorder)
                .onChange(of: pairingLink) { pairResult = nil }
                .onSubmit { pairFromLink() }
                .accessibilityIdentifier("SettingsComputersPairingLinkField")

                Button(String(localized: "settings.computers.pairingLink.add", defaultValue: "Add")) {
                    pairFromLink()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isPairingLink || pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("SettingsComputersPairingLinkAddButton")
            }
        }
    }

    @ViewBuilder
    private var pairResultCaption: some View {
        if let pairResult, let text = Self.resultText(pairResult) {
            Label(text, systemImage: pairResult == .paired ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(pairResult == .paired ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .cmuxFont(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var pairThisMacRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:computers:showPairingCode",
            String(localized: "settings.computers.showPairingCode", defaultValue: "Pair This Mac"),
            subtitle: String(
                localized: "settings.computers.showPairingCode.subtitle",
                defaultValue: "Copy a pairing link and paste it into “Add by Pairing Link” on another Mac."
            )
        ) {
            Button(String(localized: "settings.computers.copyLink.button", defaultValue: "Copy Pairing Link")) {
                copyPairingLink()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isCopyingLink)
            .accessibilityIdentifier("SettingsComputersCopyPairingLinkButton")
        }
    }

    @ViewBuilder
    private var copyLinkResultCaption: some View {
        if let copyLinkResult, let text = Self.copyLinkText(copyLinkResult) {
            Label(
                text,
                systemImage: copyLinkResult == .copied ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(copyLinkResult == .copied ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            .cmuxFont(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }

    private func pair(deviceID: String) {
        guard !pendingDeviceIDs.contains(deviceID) else { return }
        pendingDeviceIDs.insert(deviceID)
        Task {
            pairResult = await hostActions.pairComputer(deviceID: deviceID)
            pendingDeviceIDs.remove(deviceID)
        }
    }

    private func unpair(deviceID: String) {
        guard !pendingDeviceIDs.contains(deviceID) else { return }
        pendingDeviceIDs.insert(deviceID)
        Task {
            await hostActions.unpairComputer(deviceID: deviceID)
            pendingDeviceIDs.remove(deviceID)
        }
    }

    private func copyPairingLink() {
        guard !isCopyingLink else { return }
        isCopyingLink = true
        copyLinkResult = nil
        Task {
            copyLinkResult = await hostActions.copyComputerPairingLink()
            isCopyingLink = false
        }
    }

    private func pairFromLink() {
        let link = pairingLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isPairingLink, !link.isEmpty else { return }
        isPairingLink = true
        pairResult = nil
        Task {
            let result = await hostActions.pairComputerWithLink(link)
            pairResult = result
            if result == .paired { pairingLink = "" }
            isPairingLink = false
        }
    }

    private static func copyLinkText(_ result: ComputersCopyLinkResult) -> String? {
        switch result {
        case .copied:
            return String(
                localized: "settings.computers.copyLink.copied",
                defaultValue: "Link copied. Paste it into “Add by Pairing Link” on the other Mac."
            )
        case .needsTailscale:
            return String(
                localized: "settings.computers.copyLink.needsTailscale",
                defaultValue: "No reachable address. Install and sign in to Tailscale on both Macs, then try again."
            )
        case .signedOut:
            return String(
                localized: "settings.computers.copyLink.signedOut",
                defaultValue: "Sign in to cmux first, then copy the pairing link."
            )
        case .failed:
            return String(
                localized: "settings.computers.copyLink.failed",
                defaultValue: "Couldn't create a pairing link. Try again."
            )
        }
    }

    private static func resultText(_ result: ComputersPairResult) -> String? {
        switch result {
        case .paired:
            return String(localized: "settings.computers.pairResult.paired", defaultValue: "Paired.")
        case .invalidLink:
            return String(localized: "settings.computers.pairResult.invalidLink", defaultValue: "That doesn't look like a cmux pairing link.")
        case .loopbackRejected:
            return String(localized: "settings.computers.pairResult.loopback", defaultValue: "That link points back at this Mac. Pairing over the network needs Tailscale on both Macs.")
        case .accountMismatch:
            return String(localized: "settings.computers.pairResult.accountMismatch", defaultValue: "That computer is signed in to a different account.")
        case .noRoutes:
            return String(localized: "settings.computers.pairResult.noRoutes", defaultValue: "That computer hasn't advertised a reachable address yet. Make sure Tailscale is running on it.")
        case .failed:
            return String(localized: "settings.computers.pairResult.failed", defaultValue: "Pairing failed. Try again.")
        }
    }
}

/// One computer row: identity, presence, and the pair/unpair control. Receives
/// only value snapshots and action closures (snapshot boundary: no stores
/// below the `ForEach`).
private struct ComputersSectionRow: View {
    let computer: ComputersSettingsComputer
    let isPending: Bool
    let pair: () -> Void
    let unpair: () -> Void

    var body: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:computers:row:\(computer.deviceID)",
            title,
            subtitle: subtitle
        ) {
            HStack(spacing: 10) {
                presenceBadge
                control
            }
        }
    }

    private var title: String {
        if computer.isThisMac {
            return String(
                localized: "settings.computers.row.thisMac",
                defaultValue: "\(computer.name) (This Mac)"
            )
        }
        return computer.name
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let detail = computer.detail, !detail.isEmpty {
            parts.append(detail)
        }
        if let lastSeen = lastSeenText {
            parts.append(lastSeen)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var lastSeenText: String? {
        let lastSeenAt: Date?
        switch computer.presence {
        case .online:
            return nil
        case .offline(let date), .unknown(let date):
            lastSeenAt = date
        }
        guard let lastSeenAt else { return nil }
        let relative = lastSeenAt.formatted(.relative(presentation: .named))
        return String(
            localized: "settings.computers.row.lastSeen",
            defaultValue: "Last seen \(relative)"
        )
    }

    @ViewBuilder
    private var presenceBadge: some View {
        switch computer.presence {
        case .online:
            Label(
                String(localized: "settings.computers.presence.online", defaultValue: "Online"),
                systemImage: "circle.fill"
            )
            .foregroundStyle(.green)
            .cmuxFont(.caption)
        case .offline:
            Label(
                String(localized: "settings.computers.presence.offline", defaultValue: "Offline"),
                systemImage: "circle.fill"
            )
            .foregroundStyle(.secondary)
            .cmuxFont(.caption)
        case .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private var control: some View {
        if computer.isPaired, !computer.isThisMac {
            Button(String(localized: "settings.computers.row.unpair", defaultValue: "Unpair")) {
                unpair()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isPending)
            .accessibilityIdentifier("SettingsComputersUnpairButton-\(computer.deviceID)")
        } else if computer.canPair {
            Button(String(localized: "settings.computers.row.pair", defaultValue: "Pair")) {
                pair()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isPending)
            .accessibilityIdentifier("SettingsComputersPairButton-\(computer.deviceID)")
        }
    }
}
