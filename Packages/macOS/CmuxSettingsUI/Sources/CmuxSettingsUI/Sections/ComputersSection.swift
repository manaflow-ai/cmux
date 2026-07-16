import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Computers** section — the account's registered computers (from the team
/// device registry) with live presence, plus Mac-to-Mac pairing: pair a
/// listed computer in one click, or pair by typing the 6-digit code another
/// Mac is showing.
@MainActor
public struct ComputersSection: View {
    @State private var model: ComputersListModel
    @State private var presentation: JSONValueModel<ComputersPresentationMode>
    /// Device ids with a pair/unpair action in flight, so their buttons show
    /// a busy state without re-rendering unrelated rows.
    @State private var pendingDeviceIDs: Set<String> = []
    /// The typed pairing-code draft.
    @State private var codeInput: String = ""
    /// Result of the most recent pair action, shown inline under the code row.
    @State private var pairResult: ComputersPairResult?
    /// Guards overlapping code-pair submissions.
    @State private var isPairingCode = false
    /// Result of the most recent mint, shown under the Pair This Mac row.
    @State private var mintResult: ComputersPairingCodeMintResult?
    /// Guards overlapping mints.
    @State private var isMintingCode = false

    private let hostActions: SettingsHostActions

    /// Creates the Computers section bound to the host bridge.
    /// - Parameters:
    ///   - hostActions: Supplies the merged computer snapshots and the
    ///     pair/unpair/refresh actions.
    ///   - jsonStore: The `cmux.json` store backing the presentation mode.
    ///   - catalog: The setting catalog carrying `computers.presentation`.
    ///   - errorLog: Sink for JSON write failures.
    public init(
        hostActions: SettingsHostActions,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog
    ) {
        _model = State(initialValue: ComputersListModel(hostActions: hostActions))
        _presentation = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.computers.presentation,
            errorLog: errorLog
        ))
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
                pairingCodeRow
                pairResultCaption
                SettingsCardDivider()
                pairThisMacRow
                mintResultCaption
                SettingsCardDivider()
                presentationRow
            }
        }
        .task {
            startSettingsObservation([model])
            presentation.startObserving()
            hostActions.refreshComputers()
            // Periodic registry re-fetch replaces the old manual Refresh
            // button; a bounded cadence delay cancelled with the view's task,
            // not condition-polling.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                hostActions.refreshComputers()
            }
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
                    unpair: { unpair(deviceID: computer.deviceID) },
                    open: { hostActions.openComputerViewer(deviceID: computer.deviceID) }
                )
            }
        }
        if snapshot.lastRefreshFailed {
            SettingsCardNote(String(
                localized: "settings.computers.refreshFailed",
                defaultValue: "Couldn't reach the device registry. Showing locally known computers."
            ))
        }
    }

    @ViewBuilder
    private var pairingCodeRow: some View {
        SettingsCardRow(
            configurationReview: .action,
            searchAnchorID: "setting:computers:pairingCode",
            String(localized: "settings.computers.pairingCode", defaultValue: "Pair with Code"),
            subtitle: String(
                localized: "settings.computers.pairingCode.subtitle",
                defaultValue: "Type the 6-digit code shown by “Pair This Mac” on the other Mac."
            ),
            controlWidth: 200
        ) {
            HStack(spacing: 8) {
                TextField(
                    String(localized: "settings.computers.pairingCode.placeholder", defaultValue: "6-digit code"),
                    text: $codeInput
                )
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
                .onChange(of: codeInput) { pairResult = nil }
                .onSubmit { pairFromCode() }
                .accessibilityIdentifier("SettingsComputersPairingCodeField")

                Button(String(localized: "settings.computers.pairingCode.pair", defaultValue: "Pair")) {
                    pairFromCode()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isPairingCode || codeInput.filter(\.isNumber).count != 6)
                .accessibilityIdentifier("SettingsComputersPairingCodePairButton")
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
                defaultValue: "Show a 6-digit code, then type it into “Pair with Code” on another Mac."
            )
        ) {
            Button(String(localized: "settings.computers.showPairingCode.button", defaultValue: "Show Pairing Code")) {
                mintPairingCode()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isMintingCode)
            .accessibilityIdentifier("SettingsComputersShowPairingCodeButton")
        }
    }

    @ViewBuilder
    private var mintResultCaption: some View {
        switch mintResult {
        case .minted(let code, let expiresAt):
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.displayCode(code))
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("SettingsComputersPairingCodeValue")
                HStack(spacing: 4) {
                    Text(String(
                        localized: "settings.computers.showPairingCode.expiresIn",
                        defaultValue: "Expires in"
                    ))
                    Text(timerInterval: Date.now...expiresAt, countsDown: true)
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .cmuxFont(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        case .needsTailscale, .signedOut, .failed:
            if let text = Self.mintFailureText(mintResult) {
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .cmuxFont(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var presentationRow: some View {
        SettingsCardRow(
            configurationReview: .json("computers.presentation"),
            searchAnchorID: "setting:computers:presentation",
            String(localized: "settings.computers.presentation", defaultValue: "Open Computers In"),
            subtitle: presentation.current == .windows
                ? String(
                    localized: "settings.computers.presentation.windows.subtitle",
                    defaultValue: "Each paired computer opens in its own window."
                )
                : String(
                    localized: "settings.computers.presentation.sidebar.subtitle",
                    defaultValue: "Paired computers merge into the main sidebar behind its computer picker."
                )
        ) {
            Picker("", selection: Binding(get: { presentation.current }, set: { presentation.set($0) })) {
                Text(String(localized: "settings.computers.presentation.windows", defaultValue: "Separate Windows"))
                    .tag(ComputersPresentationMode.windows)
                Text(String(localized: "settings.computers.presentation.sidebar", defaultValue: "Main Sidebar"))
                    .tag(ComputersPresentationMode.sidebar)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("SettingsComputersPresentationPicker")
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

    private func mintPairingCode() {
        guard !isMintingCode else { return }
        isMintingCode = true
        mintResult = nil
        Task {
            mintResult = await hostActions.mintComputerPairingCode()
            isMintingCode = false
        }
    }

    private func pairFromCode() {
        let code = codeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isPairingCode, code.filter(\.isNumber).count == 6 else { return }
        isPairingCode = true
        pairResult = nil
        Task {
            let result = await hostActions.pairComputer(code: code)
            pairResult = result
            if result == .paired { codeInput = "" }
            isPairingCode = false
        }
    }

    /// `042117` → `042 117`: grouped for reading aloud across the room.
    static func displayCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    private static func mintFailureText(_ result: ComputersPairingCodeMintResult?) -> String? {
        switch result {
        case .minted, nil:
            return nil
        case .needsTailscale:
            return String(
                localized: "settings.computers.showPairingCode.needsTailscale",
                defaultValue: "No reachable address. Install and sign in to Tailscale on both Macs, then try again."
            )
        case .signedOut:
            return String(
                localized: "settings.computers.showPairingCode.signedOut",
                defaultValue: "Sign in to cmux first, then show a pairing code."
            )
        case .failed:
            return String(
                localized: "settings.computers.showPairingCode.failed",
                defaultValue: "Couldn't create a pairing code. Try again."
            )
        }
    }

    private static func resultText(_ result: ComputersPairResult) -> String? {
        switch result {
        case .paired:
            return String(localized: "settings.computers.pairResult.paired", defaultValue: "Paired.")
        case .invalidLink:
            return String(localized: "settings.computers.pairResult.invalidLink", defaultValue: "That doesn't look like a cmux pairing code.")
        case .codeNotFound:
            return String(
                localized: "settings.computers.pairResult.codeNotFound",
                defaultValue: "No computer is showing that code. Check the digits and that the code hasn't expired."
            )
        case .loopbackRejected:
            return String(localized: "settings.computers.pairResult.loopback", defaultValue: "That code belongs to this Mac. Enter it on the other Mac instead.")
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
    let open: () -> Void

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
            Button(String(localized: "settings.computers.row.open", defaultValue: "Open")) {
                open()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("SettingsComputersOpenButton-\(computer.deviceID)")

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
