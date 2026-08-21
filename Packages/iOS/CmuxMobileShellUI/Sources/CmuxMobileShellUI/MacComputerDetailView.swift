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
    let instanceTag: String?
    /// The route kind of the Connections row that opened this detail; its
    /// routes lead the routes section. `nil` when opened without a row.
    var focusedRouteKind: CmxAttachTransportKind? = nil
    /// Present the add-connection sheet titled for Tailscale: choosing
    /// Tailscale for this Computer without a usable grant offers it under the
    /// picker, so the choice never silently strands the Computer as
    /// Disconnected. The scanner is one tap away inside the sheet.
    var addTailscaleConnection: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var newDirectAddress = ""
    @State private var newDirectAddressLabel = ""
    @State private var showsAddDirectAddress = false
    /// Optimistic method selection: moves the picker the moment the user taps
    /// while the persist + store reload reconcile the authoritative value.
    @State private var pendingConnectionMethod: MobileConnectionMethod?

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
        store.displayPairedMacs.first {
            $0.macDeviceID == macDeviceID && $0.instanceTag == instanceTag
        }
    }
    private var connectionStatus: MobileMacConnectionStatus? {
        store.macConnectionStatuses[
            MobilePairedMac.pairingID(macDeviceID: macDeviceID, instanceTag: instanceTag)
        ] ?? MobileShellComposite.exactPairingConnectionStatus(
            deviceStatus: store.macConnectionStatuses[macDeviceID],
            connectedMacDeviceID: store.connectedMacDeviceID,
            connectedMacInstanceTag: store.connectedMacInstanceTag,
            rowMacDeviceID: macDeviceID,
            rowInstanceTag: instanceTag
        )
    }
    private var presence: PresenceMap.DeviceSummary? {
        store.presenceSummary(
            for: macDeviceID,
            instanceTag: pairedMac?.instanceTag
        )
    }
    private var isForeground: Bool {
        store.connectedMacDeviceID == macDeviceID
            && (instanceTag == nil || store.connectedMacInstanceTag == instanceTag)
    }
    private var displayTitle: String {
        let baseName = pairedMac?.resolvedName ?? macDeviceID
        return MobileIOSBuildScope.current()?.computerDisplayName(baseName) ?? baseName
    }
    private var workspaceCount: Int {
        store.workspaceCount(for: macDeviceID, instanceTag: instanceTag)
    }
    var body: some View {
        Form {
            connectionMethodSection
            appearanceSection
            connectionSection
            presenceSection
            routesSection
            identitySection
            actionsSection
        }
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            L10n.string("mobile.connections.direct.add", defaultValue: "Add Address"),
            isPresented: $showsAddDirectAddress
        ) {
            TextField(
                L10n.string(
                    "mobile.connections.direct.addPlaceholder",
                    defaultValue: "Address or address:port"
                ),
                text: $newDirectAddress
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .accessibilityIdentifier("MobileComputerDirectAddressField")
            TextField(
                L10n.string(
                    "mobile.connections.direct.labelPlaceholder",
                    defaultValue: "Label (optional)"
                ),
                text: $newDirectAddressLabel
            )
            .accessibilityIdentifier("MobileComputerDirectAddressLabelField")
            Button(L10n.string("mobile.connections.direct.addConfirm", defaultValue: "Add")) {
                addDirectAddress()
            }
            Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string(
                "mobile.connections.direct.addMessage",
                defaultValue: "Where this computer is reachable, like 192.168.1.20 or mac.local:64000. Without a port, the Mac's advertised port is used."
            ))
        }
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
    }

    // MARK: - Connection configuration

    /// This Computer's own networking configuration: the connection method it
    /// dials (Iroh or Tailscale) and its private network addresses. Both are
    /// per (device, build) and local to this iPhone.
    private var selectedMethod: MobileConnectionMethod {
        pairedMac.map { store.connectionMethod(for: $0) } ?? .automatic
    }

    /// The Settings connection-method UI, moved here verbatim (same picker
    /// style, labels, and per-method footers) now that the choice is per
    /// Computer. Private addresses live in their own section below.
    @ViewBuilder
    private var connectionMethodSection: some View {
        Section {
            Picker(
                L10n.string(
                    "mobile.settings.connectionMethod",
                    defaultValue: "Connection Method"
                ),
                selection: Binding(
                    get: { pendingConnectionMethod ?? selectedMethod },
                    set: { applyConnectionMethod($0) }
                )
            ) {
                Text(L10n.string(
                    "mobile.settings.connectionMethod.automatic",
                    defaultValue: "Iroh"
                ))
                .tag(MobileConnectionMethod.automatic)
                .accessibilityIdentifier("MobileComputerConnectionMethodIroh")
                Text(L10n.string(
                    "mobile.settings.connectionMethod.tailscale",
                    defaultValue: "Tailscale Only"
                ))
                .tag(MobileConnectionMethod.tailscale)
                .accessibilityIdentifier("MobileComputerConnectionMethodTailscale")
                Text(L10n.string(
                    "mobile.connections.method.direct",
                    defaultValue: "Direct"
                ))
                .tag(MobileConnectionMethod.direct)
                .accessibilityIdentifier("MobileComputerConnectionMethodDirect")
            }
            .accessibilityIdentifier("MobileComputerConnectionMethod")
            // Tailscale Only with no authorized route for THIS computer is
            // undialable until a Tailscale connection is added once. The
            // choice never auto-opens anything; it hints the consequence and
            // offers the add-connection sheet right under the picker for when
            // the user wants it.
            if (pendingConnectionMethod ?? selectedMethod) == .tailscale,
               !computerHasUsableTailscaleAuthorization {
                Label {
                    Text(L10n.string(
                        "mobile.connections.tailscaleUnauthorizedWarning",
                        defaultValue: "No authorized Tailscale route yet — this computer stays disconnected until you add a Tailscale connection."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .accessibilityIdentifier("MobileComputerTailscaleUnauthorizedWarning")
                if let addTailscaleConnection {
                    Button {
                        addTailscaleConnection()
                    } label: {
                        Label(
                            L10n.string(
                                "mobile.connections.tailscale.add",
                                defaultValue: "Add Tailscale Connection"
                            ),
                            systemImage: "plus.circle"
                        )
                    }
                    .accessibilityIdentifier("MobileComputerAddTailscaleConnectionButton")
                }
            }
        } footer: {
            Text(connectionMethodFooterText)
        }

        if (pendingConnectionMethod ?? selectedMethod) == .direct {
            directAddressesSection
        }
    }

    /// The Computer's Direct dial candidates: a multi-selectable list — each
    /// enabled row is a candidate, dialed in order — plus an add field.
    /// Entries accept `host` or `host:port`; without a port the Mac's
    /// advertised listener port is dialed (one listener serves all methods).
    @ViewBuilder
    private var directAddressesSection: some View {
        Section {
            ForEach(directAddressDrafts) { entry in
                Button {
                    toggleDirectAddress(entry)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: entry.enabled ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(entry.enabled ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            if let label = entry.label, !label.isEmpty {
                                Text(label)
                                    .foregroundStyle(.primary)
                                Text(entry.id)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(entry.id)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.primary)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                // Plain style keeps the row text primary/secondary; only the
                // check circle carries the accent color.
                .buttonStyle(.plain)
                .accessibilityIdentifier("MobileComputerDirectAddress-\(entry.id)")
            }
            .onDelete(perform: deleteDirectAddresses)
            Button {
                newDirectAddress = ""
                newDirectAddressLabel = ""
                showsAddDirectAddress = true
            } label: {
                Label(
                    L10n.string(
                        "mobile.connections.direct.add",
                        defaultValue: "Add Address"
                    ),
                    systemImage: "plus.circle.fill"
                )
            }
            .accessibilityIdentifier("MobileComputerDirectAddressAdd")
        } header: {
            Text(L10n.string(
                "mobile.connections.direct.title",
                defaultValue: "Direct Addresses"
            ))
        } footer: {
            Text(directAddressDrafts.contains(where: \.enabled)
                ? L10n.string(
                    "mobile.connections.direct.footer",
                    defaultValue: "Enabled addresses are dialed in order. Without a port, the Mac's advertised port is used."
                )
                : L10n.string(
                    "mobile.connections.direct.noneEnabled",
                    defaultValue: "No address is enabled — this computer stays disconnected until you enable or add one."
                ))
        }
    }

    private var directAddressDrafts: [MobilePairedMacDirectAddress] {
        pairedMac?.directAddresses ?? []
    }

    private var parsedNewDirectAddress: MobilePairedMacDirectAddress? {
        Self.parseDirectAddress(newDirectAddress)
    }

    /// Parses `host` or `host:port` (port 1...65535). IPv6 literals without
    /// brackets keep their colons by only treating the suffix as a port when
    /// exactly one colon is present.
    static func parseDirectAddress(_ raw: String) -> MobilePairedMacDirectAddress? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port),
           !parts[0].isEmpty {
            return MobilePairedMacDirectAddress(address: String(parts[0]), port: port)
        }
        guard !trimmed.contains(" ") else { return nil }
        return MobilePairedMacDirectAddress(address: trimmed, port: nil)
    }

    private func addDirectAddress() {
        guard var entry = parsedNewDirectAddress else { return }
        let trimmedLabel = newDirectAddressLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.label = trimmedLabel.isEmpty ? nil : trimmedLabel
        var drafts = directAddressDrafts
        guard !drafts.contains(where: { $0.id == entry.id }) else {
            newDirectAddress = ""
            return
        }
        drafts.append(entry)
        newDirectAddress = ""
        persistDirectAddresses(drafts)
    }

    private func toggleDirectAddress(_ entry: MobilePairedMacDirectAddress) {
        var drafts = directAddressDrafts
        guard let index = drafts.firstIndex(where: { $0.id == entry.id }) else { return }
        drafts[index].enabled.toggle()
        persistDirectAddresses(drafts)
    }

    private func deleteDirectAddresses(at offsets: IndexSet) {
        var drafts = directAddressDrafts
        drafts.remove(atOffsets: offsets)
        persistDirectAddresses(drafts)
    }

    private func persistDirectAddresses(_ drafts: [MobilePairedMacDirectAddress]) {
        Task {
            await store.setDirectAddresses(drafts, macDeviceID: macDeviceID, instanceTag: instanceTag)
        }
    }

    /// Whether THIS Computer already has a Tailscale route this iPhone is
    /// authorized to dial (grant matching an advertised route).
    private var computerHasUsableTailscaleAuthorization: Bool {
        guard let pairedMac else { return false }
        return MobileShellComposite.hasUsableTailscaleAuthorization(in: [pairedMac])
    }

    private var connectionMethodFooterText: String {
        switch pendingConnectionMethod ?? selectedMethod {
        case .direct:
            return L10n.string(
                "mobile.settings.connectionMethod.directFooter",
                defaultValue: "Dials only the direct addresses you enable below — for LAN, WireGuard, or any other network where this computer is reachable. The Mac must be signed in to the same cmux account."
            )
        case .automatic:
            return L10n.string(
                "mobile.settings.connectionMethod.automaticFooter",
                defaultValue: "Requires cmux 0.64.20 or later on your Mac. Connects automatically over an authenticated, end-to-end encrypted connection."
            )
        case .tailscale:
            return L10n.string(
                "mobile.settings.connectionMethod.tailscaleFooter",
                defaultValue: """
                Works with cmux 0.64.17 or later on your Mac. Install Tailscale on both devices, join the same \
                network, then scan the Mac's pairing code once. cmux stays disconnected until that local \
                authorization exists.
                """
            )
        }
    }

    /// Persist the per-Computer method. The pending value moves the picker
    /// immediately; the store reload reconciles it. Choosing Tailscale never
    /// auto-opens the scanner — the inline warning and Scan row carry that.
    private func applyConnectionMethod(_ method: MobileConnectionMethod) {
        guard method != (pendingConnectionMethod ?? selectedMethod) else { return }
        pendingConnectionMethod = method
        Task {
            await store.setConnectionMethod(method, macDeviceID: macDeviceID, instanceTag: instanceTag)
            pendingConnectionMethod = nil
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
                instanceTag: instanceTag,
                customName: name,
                customColor: color,
                customIcon: icon
            )
        }
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
            let prioritized = (pairedMac?.routes ?? []).sorted { $0.priority > $1.priority }
            // The route kind whose row opened this detail leads the list, so
            // the tapped connection's own leg is the first thing inspected.
            let routes = prioritized.filter { $0.kind == focusedRouteKind }
                + prioritized.filter { $0.kind != focusedRouteKind }
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
                Text(route.kind.mobileConnectionMethodName)
                    .font(.callout)
                Spacer(minLength: 8)
                Text(endpointText(route.endpoint))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if route.kind != .iroh {
                    Button {
                        Task {
                            await store.removeRoute(
                                route,
                                macDeviceID: macDeviceID,
                                instanceTag: instanceTag
                            )
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .accessibilityLabel(
                        L10n.string(
                            "mobile.connections.route.remove",
                            defaultValue: "Remove route"
                        )
                    )
                    .accessibilityIdentifier("MobileComputerRemoveRoute-\(route.id)")
                }
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
                Task {
                    await store.switchToMac(
                        macDeviceID: macDeviceID,
                        instanceTag: instanceTag
                    )
                }
            } label: {
                Label(L10n.string("mobile.workspace.reconnect", defaultValue: "Reconnect"), systemImage: "arrow.clockwise")
            }
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
