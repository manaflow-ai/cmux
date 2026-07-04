#if os(iOS)
import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Comprehensive per-computer detail + debug sheet, pushed from the Computers
/// screen. This is a single detail view (not a recycled list row), so it holds
/// the `@Bindable store` directly and pulls everything for one `macDeviceID`.
///
/// It deliberately separates the two facts the user needs to debug a connection:
/// the PHONE's live connection to the Mac (can my phone reach it?) and the
/// Durable Object presence (does the Mac say it is alive?), plus the exact routes
/// the phone would dial. A "online via presence but phone not connected" split
/// then points straight at a route/tailscale problem.
struct MacComputerDetailView: View {
    @Bindable var store: CMUXMobileShellStore
    let macDeviceID: String
    @Environment(\.dismiss) private var dismiss

    @State private var pendingRemoval = false
    /// Per-route reachability probe results, keyed by ``routeSignature(_:)``
    /// (kind + endpoint), not `route.id`: a stable id like `tailscale` can keep
    /// its id while its host/port is refreshed, so id-keying would show a stale
    /// result under a changed endpoint. Signature-keying drops the stale row.
    @State private var pingResults: [String: CmxRoutePingResult] = [:]
    /// True while a ping pass is in flight (drives the spinner + disables Ping).
    @State private var isPinging = false
    @State private var editName = ""
    @State private var customColorPick = Color.blue
    @State private var customEmoji = ""
    @State private var didLoadEdits = false
    @State private var pendingCustomName: String?
    @State private var pendingCustomColor: String?
    @State private var pendingCustomIcon: String?

    /// Curated icon choices: a few computer/utility SF Symbols + emojis.
    private static let symbolChoices = [
        "desktopcomputer", "macbook", "laptopcomputer", "server.rack",
        "terminal", "display", "bolt.fill", "star.fill", "heart.fill", "flame.fill",
    ]
    private static let emojiChoices = ["💻", "🖥️", "⚡️", "🔥", "⭐️", "🚀", "🐧", "🍎", "🎮", "👾"]

    private var pairedMac: MobilePairedMac? {
        store.displayPairedMacs.first { $0.macDeviceID == macDeviceID }
    }
    private var connectionStatus: MobileMacConnectionStatus? {
        store.macConnectionStatuses[macDeviceID]
    }
    private var presence: PresenceMap.DeviceSummary? {
        store.presenceSummary(for: macDeviceID)
    }
    private var isForeground: Bool { store.connectedMacDeviceID == macDeviceID }
    private var workspaceCount: Int {
        store.workspaceCount(for: macDeviceID)
    }
    var body: some View {
        Form {
            appearanceSection
            connectionSection
            presenceSection
            routesSection
            identitySection
            actionsSection
        }
        .navigationTitle(pairedMac?.resolvedName ?? macDeviceID)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !didLoadEdits else { return }
            didLoadEdits = true
            let mac = pairedMac
            pendingCustomName = mac?.customName
            pendingCustomColor = mac?.customColor
            pendingCustomIcon = mac?.customIcon
            editName = mac?.customName ?? ""
            if let hex = mac?.customColor, let color = Color(hexString: hex) {
                customColorPick = color
            }
        }
        .confirmationDialog(
            "\(L10n.string("mobile.computers.removeTitlePrefix", defaultValue: "Remove")) \(pairedMac?.displayName ?? macDeviceID)?",
            isPresented: $pendingRemoval,
            titleVisibility: .visible
        ) {
            Button(L10n.string("mobile.computers.remove", defaultValue: "Remove"), role: .destructive) {
                let id = macDeviceID
                Task { await store.forgetMac(macDeviceID: id); await store.loadPairedMacs() }
                dismiss()
            }
            Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(removeMessage)
        }
    }

    // MARK: - Appearance editing

    @ViewBuilder
    private var appearanceSection: some View {
        Section(L10n.string("mobile.computers.section.appearance", defaultValue: "Appearance")) {
            LabeledContent(L10n.string("mobile.computers.field.name", defaultValue: "Name")) {
                TextField(pairedMac?.displayName ?? macDeviceID, text: $editName)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .onSubmit { applyName(editName) }
                    .accessibilityIdentifier("MobileComputerNameField")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("mobile.computers.field.color", defaultValue: "Color"))
                    .font(.subheadline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        autoChip(isSelected: pendingCustomColor == nil) { applyColor(nil) }
                        ForEach(Array(MachineAvatarColors.palettes.indices), id: \.self) { i in
                            colorSwatch(index: i)
                        }
                        ColorPicker("", selection: $customColorPick, supportsOpacity: false)
                            .labelsHidden()
                            .onChange(of: customColorPick) { _, newColor in
                                if let hex = newColor.hexString { applyColor(hex) }
                            }
                    }
                    .padding(.vertical, 2)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("mobile.computers.field.icon", defaultValue: "Icon"))
                    .font(.subheadline)
                iconWrap
                TextField(
                    L10n.string("mobile.computers.field.customEmoji", defaultValue: "Custom emoji…"),
                    text: $customEmoji
                )
                .submitLabel(.done)
                .onSubmit {
                    let trimmed = customEmoji.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { applyIcon(trimmed); customEmoji = "" }
                }
            }
        }
    }

    @ViewBuilder
    private var iconWrap: some View {
        let symbols = Self.symbolChoices.map { MacAvatarIcon.symbol($0) }
        let emojis = Self.emojiChoices.map { MacAvatarIcon.emoji($0) }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
            autoChip(isSelected: pendingCustomIcon == nil) { applyIcon(nil) }
            ForEach(symbols + emojis, id: \.self) { icon in iconChip(icon) }
        }
    }

    @ViewBuilder
    private func iconChip(_ icon: MacAvatarIcon) -> some View {
        let value: String = { if case let .symbol(s) = icon { return s } else if case let .emoji(e) = icon { return e } else { return "" } }()
        let isSelected = pendingCustomIcon == value
        Button { applyIcon(value) } label: {
            Group {
                switch icon {
                case .symbol(let name): Image(systemName: name).font(.body)
                case .emoji(let emoji): Text(emoji).font(.body)
                case .image(let identifier): WorkspaceAgentLogoImage(identifier: identifier, size: 28)
                }
            }
            .frame(width: 36, height: 36)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Circle())
            .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func colorSwatch(index: Int) -> some View {
        let isSelected = pendingCustomColor == "palette:\(index)"
        Button { applyColor("palette:\(index)") } label: {
            Circle()
                .fill(MachineAvatarColors.gradient(index: index))
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(isSelected ? Color.primary : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func autoChip(isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(L10n.string("mobile.computers.auto", defaultValue: "Auto"))
                .font(.caption.weight(.medium))
                .frame(width: 36, height: 36)
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Circle())
                .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func applyName(_ name: String?) {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingCustomName = (n?.isEmpty == false) ? n : nil
        persistCustomization()
    }

    private func applyColor(_ color: String?) {
        pendingCustomColor = color
        persistCustomization()
    }

    private func applyIcon(_ icon: String?) {
        pendingCustomIcon = icon
        persistCustomization()
    }

    private func persistCustomization() {
        let name = pendingCustomName
        let color = pendingCustomColor
        let icon = pendingCustomIcon
        Task {
            await store.updateMacCustomization(
                macDeviceID: macDeviceID,
                customName: name,
                customColor: color,
                customIcon: icon
            )
        }
    }

    private var removeMessage: String {
        L10n.string(
            "mobile.computers.removeMessage",
            defaultValue: "This computer and its workspaces stop appearing here. Pair it again to add it back."
        )
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section(L10n.string("mobile.computers.section.connection", defaultValue: "Connection")) {
            LabeledContent(L10n.string("mobile.computers.field.phone", defaultValue: "This phone")) {
                Label(connectionPhrase, systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(connectionColor)
                    .font(.callout)
            }
            if isForeground {
                LabeledContent(L10n.string("mobile.computers.field.role", defaultValue: "Role"),
                               value: L10n.string("mobile.computers.role.foreground", defaultValue: "Active (foreground)"))
            }
            LabeledContent(L10n.string("mobile.computers.field.workspaces", defaultValue: "Workspaces"),
                           value: "\(workspaceCount)")
        }
    }

    @ViewBuilder
    private var presenceSection: some View {
        Section {
            if let presence {
                LabeledContent(L10n.string("mobile.computers.field.reported", defaultValue: "Reports"),
                               value: presence.online
                                ? L10n.string("mobile.deviceTree.online", defaultValue: "Online")
                                : L10n.string("mobile.deviceTree.offline", defaultValue: "Offline"))
                if let buildLabel = presence.buildLabel {
                    LabeledContent(
                        L10n.string("mobile.computers.field.build", defaultValue: "Build"),
                        value: buildLabel)
                }
                LabeledContent(L10n.string("mobile.computers.field.lastSeen", defaultValue: "Last seen"),
                               value: presence.lastSeenAt.formatted(.relative(presentation: .named)))
            } else if connectionStatus == .connected {
                // No server heartbeat, but the phone is connected to this Mac right
                // now — so it IS online; the live connection is the liveness truth.
                // Lead with that instead of a bare "unknown"/"no heartbeat" that
                // contradicts the green Connection section. The clarifier explains
                // why there's no server record (presence heartbeat is currently a
                // dev-only feature; stable Macs don't announce it yet).
                LabeledContent(
                    L10n.string("mobile.computers.field.reported", defaultValue: "Reports"),
                    value: L10n.string("mobile.deviceTree.online", defaultValue: "Online"))
                LabeledContent(
                    L10n.string("mobile.computers.field.source", defaultValue: "Source"),
                    value: L10n.string(
                        "mobile.computers.presenceViaConnection",
                        defaultValue: "this phone's connection (no server heartbeat)"))
            } else {
                LabeledContent(L10n.string("mobile.computers.field.reported", defaultValue: "Reports"),
                               value: L10n.string("mobile.computers.presenceUnknown", defaultValue: "unknown"))
            }
        } header: {
            Text(L10n.string("mobile.computers.section.presence", defaultValue: "Presence (from server)"))
        } footer: {
            Text(L10n.string("mobile.computers.presenceFooter",
                defaultValue: "Presence is the Mac's own heartbeat to the presence service, which is currently a DEV-only feature. Stable cmux Macs don't announce it yet, so a Mac you're connected to may show no server heartbeat. If presence says online but This phone is not connected, the Mac is reachable elsewhere but not from your phone, usually a Tailscale or route problem."))
        }
    }

    @ViewBuilder
    private var routesSection: some View {
        Section {
            let routes = (pairedMac?.routes ?? []).sorted { $0.priority > $1.priority }
            if routes.isEmpty {
                Text(L10n.string("mobile.computers.noRoute", defaultValue: "no route"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(routes, id: \.id) { route in
                    routeRow(route)
                }
                Button {
                    pingAllRoutes(routes)
                } label: {
                    Label {
                        Text(isPinging
                            ? L10n.string("mobile.computers.pinging", defaultValue: "Pinging…")
                            : L10n.string("mobile.computers.ping", defaultValue: "Ping"))
                    } icon: {
                        if isPinging {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "wave.3.right")
                        }
                    }
                }
                .disabled(isPinging)
                .accessibilityIdentifier("MobileComputerPingButton")
            }
        } header: {
            Text(L10n.string("mobile.computers.section.routes", defaultValue: "Routes the phone can dial"))
        } footer: {
            Text(L10n.string(
                "mobile.computers.pingFooter",
                defaultValue: "Ping opens a direct connection to each route to check if this phone can reach the Mac right now. It works even when a workspace shows Disconnected, which usually means the live stream dropped, not that the Mac is offline."))
        }
    }

    /// One route: kind + endpoint, with its latest ping status underneath.
    @ViewBuilder
    private func routeRow(_ route: CmxAttachRoute) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(route.kind.rawValue)
                    .font(.callout)
                Spacer(minLength: 8)
                Text(endpointText(route.endpoint))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            pingStatusLine(for: route)
        }
    }

    /// The per-route ping status sub-line: nothing before the first ping, a
    /// spinner while in flight, then the classified result with a tinted icon.
    /// A stable per-endpoint key: route kind + the host/port it dials. Used to
    /// match a ping result to the row it was measured for, so a refreshed
    /// endpoint (same id, new host/port) does not inherit a stale result.
    private func routeSignature(_ route: CmxAttachRoute) -> String {
        "\(route.kind.rawValue)|\(endpointText(route.endpoint))"
    }

    @ViewBuilder
    private func pingStatusLine(for route: CmxAttachRoute) -> some View {
        if let result = pingResults[routeSignature(route)] {
            Label {
                Text(result.pingLabel)
                    .font(.caption)
                    .foregroundStyle(result.pingColor)
            } icon: {
                Image(systemName: result.pingSymbol)
                    .font(.caption)
                    .foregroundStyle(result.pingColor)
            }
            .accessibilityIdentifier("MobileComputerPingResult-\(route.id)")
        } else if isPinging {
            Label {
                Text(L10n.string("mobile.computers.pinging", defaultValue: "Pinging…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
                ProgressView().controlSize(.mini)
            }
        }
    }

    /// Probe every route in parallel and record each outcome as it lands, so
    /// fast routes show a result while slow ones are still resolving.
    private func pingAllRoutes(_ routes: [CmxAttachRoute]) {
        guard !routes.isEmpty, !isPinging else { return }
        isPinging = true
        pingResults = [:]
        let store = store
        let signatures = Dictionary(
            routes.map { (routeSignature($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        Task {
            await withTaskGroup(of: (String, CmxRoutePingResult).self) { group in
                for (signature, route) in signatures {
                    group.addTask { (signature, await store.pingRoute(route)) }
                }
                for await (signature, result) in group {
                    pingResults[signature] = result
                }
            }
            isPinging = false
        }
    }

    @ViewBuilder
    private var identitySection: some View {
        Section(L10n.string("mobile.computers.section.identity", defaultValue: "Identity")) {
            LabeledContent(L10n.string("mobile.computers.field.deviceId", defaultValue: "Device ID")) {
                Text(macDeviceID).font(.callout.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            if let createdAt = pairedMac?.createdAt {
                LabeledContent(L10n.string("mobile.computers.field.pairedSince", defaultValue: "Paired since"),
                               value: createdAt.formatted(.dateTime.month().day().year()))
            }
            if let lastSeenAt = pairedMac?.lastSeenAt {
                LabeledContent(L10n.string("mobile.computers.field.routeUpdated", defaultValue: "Route updated"),
                               value: lastSeenAt.formatted(.relative(presentation: .named)))
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            Button {
                // Reconnect THIS computer, not whichever Mac is currently active:
                // `switchToMac` promotes a live secondary connection to this Mac or
                // re-dials it specifically. `reconnectOrRefresh()` would instead
                // refresh/redial the foreground/active Mac and leave the computer
                // shown here untouched.
                Task { await store.switchToMac(macDeviceID: macDeviceID) }
            } label: {
                Label(L10n.string("mobile.workspace.reconnect", defaultValue: "Reconnect"), systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                pendingRemoval = true
            } label: {
                Label(L10n.string("mobile.computers.remove", defaultValue: "Remove"), systemImage: "trash")
            }
            .accessibilityIdentifier("MobileComputerDetailRemove")
        }
    }

    private var connectionPhrase: String {
        switch connectionStatus {
        case .connected: return L10n.string("mobile.deviceTree.connected", defaultValue: "Connected")
        case .reconnecting: return L10n.string("mobile.deviceTree.reconnecting", defaultValue: "Reconnecting…")
        case .unavailable, nil: return L10n.string("mobile.computers.notConnected", defaultValue: "Not connected")
        }
    }

    private var connectionColor: Color {
        switch connectionStatus {
        case .connected: return .green
        case .reconnecting: return .orange
        case .unavailable, nil: return .secondary
        }
    }

    private func endpointText(_ endpoint: CmxAttachEndpoint) -> String {
        if case let .hostPort(host, port) = endpoint { return "\(host):\(port)" }
        return "—"
    }
}
#endif
