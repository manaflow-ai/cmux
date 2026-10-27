#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// The live service behind Settings → Devices and account deletion (the
/// shell supplies it; mock mode has none).
@MainActor
public protocol SettingsDeviceDirectory: AnyObject {
    func devices() async throws -> [SettingsDevice]
    func remove(_ device: SettingsDevice) async throws
    /// Whether the service has a TURN relay (nil: not known yet).
    var relayAvailable: Bool? { get }
    /// Account deletion, first step: the service forgets this account.
    func deleteAccountData() async throws
    /// "Remove This iPhone from My Macs": the linked Mac forgets this phone,
    /// its pairing keys are replaced, and the next connection asks the Mac
    /// again. Sign-out does not do this (verify/persistence.md).
    func removeThisPhoneFromMacs() async
    /// A scanned Mac pairing code (`cmux-next://pair?…`): the phone moves to
    /// that Mac and pairs with it. False when the text is no live code for this account.
    func openPairingCode(_ text: String) -> Bool
}

extension SettingsDeviceDirectory {
    public func openPairingCode(_ text: String) -> Bool { false }
}

/// The account's devices from the service, shared by the Settings root (its
/// "Devices" count) and the Devices page, so both read one list.
@MainActor
@Observable
final class SettingsDeviceList {
    /// The service's list; nil until it loads (or with no service).
    private(set) var devices: [SettingsDevice]?
    private(set) var loadError: String?

    func load(_ directory: (any SettingsDeviceDirectory)?) async {
        guard let directory else { return }
        do {
            devices = try await directory.devices()
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = "Couldn't load your devices. Pull to try again."
        }
    }

    func removed(_ device: SettingsDevice) {
        devices?.removeAll { $0.id == device.id }
    }

    /// The Mac rows (see `SettingsDeviceRows.macs`); nil while loading.
    func macs(store: AppStore, hasService: Bool) -> [SettingsDevice]? {
        SettingsDeviceRows.macs(service: devices, hasService: hasService, liveMacs: store.teams.flatMap(\.macs),
                                teamOf: store.teams.reduce(into: [:]) { out, team in for mac in team.macs where out[mac.id] == nil { out[mac.id] = team.id } })
    }

    var phones: [SettingsDevice] { SettingsDeviceRows.phones(service: devices) }
}

/// Settings → Devices: the account's Macs and phones from the service, with
/// real presence; stale ones can be removed.
struct DevicesPage: View {
    let store: AppStore
    let directory: (any SettingsDeviceDirectory)?
    let list: SettingsDeviceList
    @State private var pendingRemoval: SettingsDevice?
    @State private var confirmingPhoneRemoval = false
    @State private var removingPhone = false
    @State private var removalError: ServiceFailureMessage?
    /// Rows whose removal is in flight (shown dimmed, not removable twice).
    @State private var removing: Set<String> = []
    /// "Scan QR on your Mac" is open.
    @State private var scanning = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var dotSize: CGFloat = 8
    @ScaledMetric(relativeTo: .body) private var dotLift: CGFloat = 6

    var body: some View {
        List {
            if let relay = directory?.relayAvailable, !relay {
                Section {
                    CmuxMobileGutterRow {
                        SettingsIcon("exclamationmark.triangle").accessibilityHidden(true)
                    } content: {
                        Text("Relay unavailable. Connections from outside your network may fail.")
                    }
                    .font(theme.type.meta)
                    .foregroundStyle(theme.colors.label2)
                    .accessibilityElement(children: .combine)
                }
            }
            Section {
                if macs.isEmpty {
                    Text(loadedMacs == nil ? "Loading…" : "No Macs yet. Open cmux on your Mac and sign in with this account.")
                        .font(theme.type.meta).foregroundStyle(theme.colors.label2)
                        .cmuxMobileTextColumn()
                }
                ForEach(macs) { mac in
                    removableRow(mac)
                }
                .onDelete { offsets in pendingRemoval = offsets.first.map { macs[$0] } }
                if directory != nil {
                    Button {
                        scanning = true
                    } label: {
                        CmuxMobileGutterRow {
                            SettingsIcon("qrcode.viewfinder").accessibilityHidden(true)
                        } content: {
                            Text("Scan QR on your Mac").font(theme.type.rowTitle)
                        }
                    }
                    .accessibilityIdentifier("settings.scanMacCode")
                }
            } header: {
                Text("Macs").cmuxMobileTextColumn()
            } footer: {
                if directory != nil {
                    Text("Remove a Mac you no longer use. It comes back if cmux on that Mac signs in again.").cmuxMobileTextColumn()
                }
            }
            if directory != nil, !phones.isEmpty {
                Section {
                    ForEach(phones) { phone in
                        removableRow(phone)
                    }
                    .onDelete { offsets in pendingRemoval = offsets.first.map { phones[$0] } }
                } header: {
                    Text("Phones").cmuxMobileTextColumn()
                } footer: {
                    Text(directory != nil ? "To remove this iPhone, use Remove This iPhone from My Macs below." : "Sign out to remove this iPhone.")
                        .cmuxMobileTextColumn()
                }
            }
            if directory != nil {
                Section {
                    Button(role: .destructive) {
                        confirmingPhoneRemoval = true
                    } label: {
                        Text(removingPhone ? "Removing…" : "Remove This iPhone from My Macs")
                            .cmuxMobileTextColumn()
                    }
                    .disabled(removingPhone)
                    .accessibilityIdentifier("settings.removeThisPhone")
                } footer: {
                    Text("Signing out keeps this iPhone allowed on your Macs. Remove it to make each Mac ask again before it connects.")
                        .cmuxMobileTextColumn()
                }
            }
            if let loadError = list.loadError {
                Section { Text(loadError).font(theme.type.meta).foregroundStyle(theme.colors.danger).cmuxMobileTextColumn() }
            }
        }
        .settingsPage("Devices")
        .sheet(isPresented: $scanning) {
            PairCodeScannerSheet { directory?.openPairingCode($0) ?? false }
        }
        .toolbar { if directory != nil { EditButton() } }
        .refreshable { await list.load(directory) }
        .task { await list.load(directory) }
        // A centered alert, with no arrow: a popover from the page pointed at
        // whichever row it chose, so with same-name Macs it could point at the
        // other Mac. A dialog attached to the swiped row does not present in a
        // List on iOS 27. The title names the Mac with its tag.
        .alert(
            pendingRemoval.map { "Remove \(displayName($0))?" } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { device in
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { Task { await remove(device) } }
        } message: { device in
            Text(Self.removalExplanation(device, connected: isConnected(device), honorsRemoval: honorsRemoval(device),
                                         displayName: displayName(device)))
        }
        .alert("Remove this iPhone from your Macs?", isPresented: $confirmingPhoneRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { Task { await removeThisPhone() } }
        } message: {
            Text("Your Mac forgets this iPhone and its keys are replaced. The next time it connects, the Mac asks you to allow it again. You stay signed in.")
        }
        .alert("Couldn't remove", isPresented: Binding(get: { removalError != nil }, set: { if !$0 { removalError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalError?.display ?? "")
        }
    }

    private var loadedMacs: [SettingsDevice]? { list.macs(store: store, hasService: directory != nil) }
    private var macs: [SettingsDevice] { loadedMacs ?? [] }
    /// Mac rows that are another cmux build of a listed Mac.
    private var otherBuilds: Set<String> { SettingsDeviceRows.otherBuilds(macs) }
    private var phones: [SettingsDevice] { list.phones }

    /// Tags for Macs that share a name ("Aziz's MacBook Pro" twice), so
    /// the rows and the remove confirmation say which one. Over the account's
    /// Macs, as Workspaces computes them, so a Mac has one tag everywhere.
    private var sameNames: MacNameDisambiguation {
        MacNameDisambiguation(account: store.teams)
    }

    /// The name with its tag when another Mac has the same name: the text the
    /// row shows (name, then the tag capsule) and the confirmation's title.
    private func displayName(_ device: SettingsDevice) -> String {
        device.kind == .mac ? sameNames.displayName(id: device.id, name: device.name) : device.name
    }

    private func canRemove(_ device: SettingsDevice) -> Bool {
        directory != nil && !device.isThisDevice && !removing.contains(device.id)
    }

    /// A row with its Remove paths: the trailing swipe, the context menu, and
    /// Edit's delete control (`onDelete`). The confirmation is a centered
    /// alert (see `body`).
    @ViewBuilder private func removableRow(_ device: SettingsDevice) -> some View {
        row(device)
            .opacity(removing.contains(device.id) ? 0.5 : 1)
            .swipeActions(edge: .trailing) {
                if canRemove(device) {
                    Button("Remove", systemImage: "trash", role: .destructive) { pendingRemoval = device }
                        // The app tints controls with the foreground color (white
                        // in dark mode), which made a blank white pill. Back to
                        // the system tint: red for the role.
                        .tint(nil)
                }
            }
            .contextMenu {
                if canRemove(device) {
                    Button(device.kind == .mac ? "Remove Mac" : "Remove iPhone", systemImage: "trash", role: .destructive) {
                        pendingRemoval = device
                    }
                }
            }
    }

    /// Whether this phone's link is on the Mac now (or dialing it).
    private func isConnected(_ device: SettingsDevice) -> Bool {
        device.kind == .mac && device.ids.contains { store.macConnection[$0] != nil }
    }

    /// Whether the Mac's host keeps itself off after a removal (`removal-v1`, said by its
    /// `version` service when this phone linked to it). Unknown counts as no.
    private func honorsRemoval(_ device: SettingsDevice) -> Bool {
        MacRemovalCopy.honorsRemoval(device.ids.map { store.macCapabilities[$0] })
    }

    /// The confirmation's message: what removal does, and how the device comes back.
    /// `honorsRemoval`: the Mac stays off once removed; an older Mac adds itself back.
    /// `displayName`: the name as the list tells it apart (defaults to the name).
    static func removalExplanation(_ device: SettingsDevice, connected: Bool, honorsRemoval: Bool = false,
                                   displayName: String? = nil) -> String {
        guard device.kind == .mac else {
            // The account's device list is all this removes: a Mac keeps its approval of the
            // phone (its paired list) until it is removed there too.
            return "It stops receiving notifications and leaves this list. Your Macs still allow it to connect until you remove it in Settings → Mobile on each Mac. It comes back here when cmux on it signs in again."
        }
        var parts = ["\(displayName ?? device.name) leaves the Mac list on all your devices, and this iPhone forgets its saved workspaces."]
        if connected { parts.append("This iPhone disconnects from it now.") }
        if device.online == true {
            parts.append(MacRemovalCopy.online(honorsRemoval: honorsRemoval))
        } else {
            parts.append("To use it again, sign in to cmux on that Mac or turn on Settings → Mobile there.")
        }
        return parts.joined(separator: " ")
    }

    @ViewBuilder private func row(_ device: SettingsDevice) -> some View {
        // The dot or glyph in the icon column; the name at the headers' x.
        CmuxMobileGutterRow(alignment: .firstTextBaseline) {
            Group {
                if device.kind == .mac {
                    // 8 pt at Large, growing with the text up to 16 pt.
                    StatusDot(Self.dot(status(device)?.dot ?? (device.online == true ? .connected : .offline)),
                              size: min(dotSize, 16))
                } else {
                    SettingsIcon("iphone")
                }
            }
            // Centered on the name's line, not the two-line block (the offset
            // from the baseline is about half the text's cap height).
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + dotLift }
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                let tag = device.kind == .mac ? sameNames.tag(for: device.id) : nil
                if typeSize.isAccessibilitySize {
                    // The tag on its own line: beside the name it would squeeze
                    // the name into one word per line.
                    UnbrokenText(device.name)
                    if let tag { MacNameTag(tag) }
                } else {
                    HStack(spacing: 6) {
                        Text(device.name).font(theme.type.rowTitle)
                        if let tag { MacNameTag(tag) }
                    }
                }
                Text(subtitle(device)).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                if device.kind == .mac, device.online == true,
                   let link = device.ids.lazy.compactMap({ store.macLinkStatus[$0] }).first {
                    Text(link).font(theme.type.meta).foregroundStyle(theme.colors.label2).lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        // By device id: same-name Macs stay distinct for tests and the rig.
        .accessibilityIdentifier(device.kind == .mac ? "settings.pairedMacs.\(device.id)" : "settings.pairedPhones.\(device.id)")
        .deleteDisabled(!canRemove(device))
    }

    private func subtitle(_ device: SettingsDevice) -> String {
        if device.kind == .phone {
            let notifications = device.receivesNotifications ? "Notifications on" : "Notifications off"
            return device.isThisDevice ? "This iPhone · \(notifications)" : notifications
        }
        let presence: String
        if device.online == true {
            presence = status(device)?.text ?? "Online"
        } else if let seen = device.lastSeenAt {
            // The formatter and clock Workspaces uses ("Last seen 2h ago"); reading
            // the clock redraws the page on each minute tick.
            presence = RelativeStamp(now: MinuteClock.shared.now).presence(isOnline: false, lastSeenAt: seen)
        } else {
            presence = "Offline"
        }
        let build = otherBuilds.contains(device.id) ? ["Another cmux build on this Mac"] : []
        // Same-name Macs: when each was added (the tag is next to the name).
        let added = sameNames.added(for: device.id, addedAt: device.addedAt).map { [$0] } ?? []
        return ([presence] + build + added).joined(separator: " · ")
    }

    /// Presence plus this phone's own connection, for a Mac this phone knows:
    /// green "Online" only while connected.
    private func status(_ device: SettingsDevice) -> MacStatusLine? {
        guard device.kind == .mac, device.online == true else { return nil }
        let mac = MacDevice(id: device.ids.first(where: { store.macConnection[$0] != nil }) ?? device.ids.first ?? "",
                            name: device.name, isOnline: true, lastSeenAt: device.lastSeenAt)
        return store.macStatusLine(mac, presence: "Online")
    }

    static func dot(_ dot: MacStatusLine.Dot) -> StatusDot.State {
        switch dot {
        case .connected: .online
        case .connecting: .busy
        case .failed: .error
        case .offline: .offline
        }
    }

    private func removeThisPhone() async {
        guard let directory, !removingPhone else { return }
        removingPhone = true
        defer { removingPhone = false }
        await directory.removeThisPhoneFromMacs()
        theme.haptics.success()
    }

    private func remove(_ device: SettingsDevice) async {
        guard let directory, !removing.contains(device.id) else { return }
        removing.insert(device.id)
        defer { removing.remove(device.id) }
        do {
            try await directory.remove(device)
            list.removed(device)
            theme.haptics.success()
        } catch let failure as ServiceFailureMessage {
            removalError = failure
            theme.haptics.error()
        } catch {
            removalError = ServiceFailureMessage(text: "Couldn't remove \(displayName(device)): \(error.localizedDescription)")
            theme.haptics.error()
        }
    }
}
#endif
