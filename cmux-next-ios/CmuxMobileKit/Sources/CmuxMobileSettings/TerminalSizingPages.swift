#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import CmuxSpinner
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// The mode picker, its explanation and, in Priority Order, the reorderable
/// device list (visible ranks and drag handles, always in reorder mode, as
/// in the classic app's size sheet, PR #18866).
struct HostSizePolicyEditor: View {
    let model: HostSizePolicyModel
    /// Who is on the terminal now (the Connected Devices sheet), for names.
    var presentation: TerminalSizingPresentation?
    /// A failed read is asked again on its own (no button): "Asking the Mac…" stays through a
    /// short failure; past the quiet bound the section says why, with the quiet line.
    @State private var autoRetry = AutoRetry()
    /// A retry is out: the failure counts until it answers (`reload` shows loading meanwhile).
    @State private var retrying = false

    private var failed: Bool {
        if case .failed = model.load { return true }
        return false
    }

    var body: some View {
        Group {
            switch model.load {
            case .loading:
                asking
            case .failed(let message):
                if autoRetry.isQuietLineShown {
                    Section {
                        Text(message).foregroundStyle(theme.colors.label2)
                        AutoRetryQuietLine(autoRetry)
                    }
                    .accessibilityIdentifier("sizing.failed")
                } else {
                    asking
                }
            case .loaded(let info):
                loaded(info)
            }
        }
        .autoRetry(autoRetry, failing: failed || retrying) {
            retrying = true
            await model.reload()
            retrying = false
        }
    }

    private var asking: some View {
        Section {
            HStack(spacing: 10) {
                CmuxSpinner()
                Text("Asking the Mac…").foregroundStyle(theme.colors.label2)
            }
        }
    }

    private func names(_ info: HostSizePolicyInfo) -> TerminalSizingPresentation {
        var names = presentation ?? TerminalSizingPresentation(state: nil, selfParticipant: nil, macParticipants: [], thisDeviceID: nil)
        names.macParticipants.formUnion(info.macParticipants)
        if names.thisDeviceID == nil { names.thisDeviceID = model.thisDeviceID }
        return names
    }

    @ViewBuilder private func loaded(_ info: HostSizePolicyInfo) -> some View {
        Section {
            Picker(selection: Binding(
                get: { info.policy.mode },
                set: { mode in
                    var policy = info.policy
                    policy.mode = mode
                    if mode == .priority, policy.order.isEmpty {
                        // Entering Priority ranks every device in sight at once.
                        policy.order = names(info).orderRows([]).map(\.token)
                    }
                    Task { await model.save(policy) }
                }
            )) {
                ForEach(HostSizeMode.allCases) { Text($0.title).tag($0) }
            } label: {
                Text("Size")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("sizing.mode")
        } header: {
            Text("Terminal Size When Shared")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(info.policy.mode.explanation)
                if let error = model.saveError {
                    Text(error).foregroundStyle(theme.colors.dangerText)
                }
            }
        }
        if info.policy.mode == .priority {
            let rows = names(info).orderRows(info.policy.order)
            Section {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(theme.type.meta.monospacedDigit())
                            .foregroundStyle(theme.colors.label2)
                            .frame(minWidth: 18)
                        Image(systemName: row.symbol).foregroundStyle(theme.colors.label2)
                        Text(row.title)
                    }
                    .accessibilityIdentifier("sizing.order.\(index + 1)")
                }
                .onMove { source, destination in
                    var policy = info.policy
                    policy.order = TerminalSizingPresentation.reordered(rows, from: source, to: destination)
                    Task { await model.save(policy) }
                }
            } header: {
                Text("Priority Order")
            }
            .environment(\.editMode, .constant(.active))
        }
    }
}

/// Settings → Terminal → Terminal Size When Shared: the phone's Macs.
struct TerminalSizingMacsPage: View {
    let store: AppStore
    let accountID: String?
    let directory: (any SettingsDeviceDirectory)?
    let list: SettingsDeviceList

    private var macs: [MacDevice] {
        SettingsDeviceRows.sizingMacs(teams: store.teams, activeTeamID: store.activeTeamID, service: list.devices, accountID: accountID,
                                     peers: directory?.terminalSizingPeers?.visible(in: store.teams) ?? [])
    }

    var body: some View {
        List {
            Section {
                if macs.isEmpty, list.devices == nil, store.awaitsAccountData {
                    // placeholder-ok: This account has no kept roster and discovery has never answered.
                    CmuxSpinner(label: Text("Loading Macs…"))
                        .placeholderBound("settings.macs.loading", .milliseconds(2000))
                } else if macs.isEmpty {
                    Text("No Macs.").foregroundStyle(theme.colors.label2)
                }
                ForEach(macs) { mac in
                    NavigationLink(value: SettingsRoute.terminalSizingMac(mac.id)) {
                        SettingsLabel("\(mac.name)", symbol: "laptopcomputer")
                    }
                }
            } footer: {
                Text("How a terminal is sized when this iPhone and other devices show it at once. Each Mac keeps its own setting.")
            }
        }
        .settingsPage("Terminal Size When Shared")
        .task(id: directory.map(ObjectIdentifier.init)) { await list.load(directory) }
    }
}

/// One Mac's sizing policy.
struct TerminalSizingMacPage: View {
    let macID: String
    let store: AppStore
    let list: SettingsDeviceList
    let peers: TerminalSizingPeers?
    @State private var model: HostSizePolicyModel

    init(macID: String, store: AppStore, list: SettingsDeviceList, peers: TerminalSizingPeers?, service: (any TerminalSizingService)?) {
        self.macID = macID
        self.store = store
        self.list = list
        self.peers = peers
        _model = State(initialValue: HostSizePolicyModel(macID: macID, service: service))
    }

    private var title: String {
        store.teams.flatMap(\.macs).first { $0.id == macID }?.name
            ?? list.devices?.first { $0.kind == .mac && $0.id == macID }?.name
            ?? peers?.visible(in: store.teams).first { $0.id == macID }?.name ?? "Mac"
    }

    var body: some View {
        List {
            HostSizePolicyEditor(model: model)
        }
        .settingsPage("\(title)")
        // Asked again when the Mac's link comes up.
        .task(id: store.macConnection[macID] == .connected) { await model.reload() }
    }
}

/// The terminal title menu's Connected Devices: the grid and why, every
/// connected viewer with the size it asks for and who sets the grid, and
/// the terminal's Mac's policy.
public struct TerminalConnectedDevicesSheet: View {
    let live: TerminalSizingLive
    @State private var model: HostSizePolicyModel
    @Environment(\.dismiss) private var dismiss

    public init(live: TerminalSizingLive, macID: String, surface: Int, service: (any TerminalSizingService)?) {
        self.live = live
        _model = State(initialValue: HostSizePolicyModel(macID: macID, surface: surface, service: service))
    }

    private var presentation: TerminalSizingPresentation {
        TerminalSizingPresentation(state: live.state, selfParticipant: live.selfParticipant,
                                   macParticipants: model.info?.macParticipants ?? [], thisDeviceID: model.thisDeviceID)
    }

    public var body: some View {
        NavigationStack {
            List {
                let presentation = presentation
                Section {
                    if let grid = presentation.gridTitle {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(grid).font(theme.type.rowTitle.monospacedDigit())
                            if let reason = presentation.reasonText {
                                Text(reason).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                            }
                        }
                        .accessibilityIdentifier("sizing.grid")
                    } else {
                        Text("This Mac doesn't share its terminal size yet.").foregroundStyle(theme.colors.label2)
                    }
                }
                if !presentation.rows.isEmpty {
                    Section("Connected") {
                        ForEach(presentation.rows) { row in
                            HStack(spacing: 12) {
                                Image(systemName: row.symbol).foregroundStyle(theme.colors.label2).frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title)
                                    Text(row.detail).font(theme.type.meta.monospacedDigit()).foregroundStyle(theme.colors.label2)
                                }
                                Spacer()
                                if row.setsSize {
                                    Text("Sets size").font(theme.type.meta).foregroundStyle(theme.colors.label2)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("sizing.row.\(row.id)")
                        }
                    }
                }
                HostSizePolicyEditor(model: model, presentation: presentation)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Connected Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.reload() }
            // The Mac's own views change as panes come and go.
            .onChange(of: live.state?.participants.map(\.id)) { _, _ in Task { await model.reload() } }
        }
    }
}
#endif
