#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// The mode picker, its explanation and, in Priority Order, the reorderable
/// device list (visible ranks and drag handles, always in reorder mode, as
/// in the classic app's size sheet, PR #18866).
struct HostSizePolicyEditor: View {
    let model: HostSizePolicyModel
    /// Who is on the terminal now (the Connected Devices sheet), for names.
    var presentation: TerminalSizingPresentation?

    var body: some View {
        switch model.load {
        case .loading:
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Asking the Mac…").foregroundStyle(theme.colors.label2)
                }
            }
        case .failed(let message):
            Section {
                Text(message).foregroundStyle(theme.colors.label2)
                Button("Try Again") { Task { await model.reload() } }
                    .accessibilityIdentifier("sizing.retry")
            }
        case .loaded(let info):
            loaded(info)
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

    private var macs: [MacDevice] {
        MacRoster(store.teams.flatMap(\.macs)).visible
    }

    var body: some View {
        List {
            Section {
                if macs.isEmpty {
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
    }
}

/// One Mac's sizing policy.
struct TerminalSizingMacPage: View {
    let macID: String
    let store: AppStore
    @State private var model: HostSizePolicyModel

    init(macID: String, store: AppStore, service: (any TerminalSizingService)?) {
        self.macID = macID
        self.store = store
        _model = State(initialValue: HostSizePolicyModel(macID: macID, service: service))
    }

    private var title: String {
        store.teams.flatMap(\.macs).first { $0.id == macID }?.name ?? "Mac"
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
