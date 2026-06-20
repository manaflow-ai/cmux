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

    private var pairedMac: MobilePairedMac? {
        store.pairedMacs.first { $0.macDeviceID == macDeviceID }
    }
    private var connectionStatus: MobileMacConnectionStatus? {
        store.macConnectionStatuses[macDeviceID]
    }
    private var presence: PresenceMap.DeviceSummary? {
        store.presenceMap.deviceSummary(deviceId: macDeviceID)
    }
    private var isForeground: Bool { store.connectedMacDeviceID == macDeviceID }
    private var workspaceCount: Int {
        store.workspaces.filter { $0.macDeviceID == macDeviceID }.count
    }

    var body: some View {
        Form {
            connectionSection
            presenceSection
            routesSection
            identitySection
            actionsSection
        }
        .navigationTitle(pairedMac?.displayName ?? macDeviceID)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            String(format: L10n.string("mobile.computers.removeTitleFormat", defaultValue: "Remove %@?"),
                   pairedMac?.displayName ?? macDeviceID),
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
            Text(L10n.string("mobile.computers.removeMessage",
                             defaultValue: "This computer and its workspaces stop appearing here. Pair it again to add it back."))
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
                LabeledContent(L10n.string("mobile.computers.field.lastSeen", defaultValue: "Last seen"),
                               value: presence.lastSeenAt.formatted(.relative(presentation: .named)))
            } else {
                LabeledContent(L10n.string("mobile.computers.field.reported", defaultValue: "Reports"),
                               value: L10n.string("mobile.computers.presenceUnknown", defaultValue: "unknown"))
            }
        } header: {
            Text(L10n.string("mobile.computers.section.presence", defaultValue: "Presence (from server)"))
        } footer: {
            Text(L10n.string("mobile.computers.presenceFooter",
                defaultValue: "Presence is the Mac's own heartbeat to the presence service, not your phone's connection. If presence says online but This phone is not connected, the Mac is reachable elsewhere but not from your phone — usually a Tailscale or route problem."))
        }
    }

    @ViewBuilder
    private var routesSection: some View {
        Section {
            let routes = pairedMac?.routes ?? []
            if routes.isEmpty {
                Text(L10n.string("mobile.computers.noRoute", defaultValue: "no route"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(routes.sorted { $0.priority > $1.priority }, id: \.id) { route in
                    LabeledContent(route.kind.rawValue) {
                        Text(endpointText(route.endpoint))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text(L10n.string("mobile.computers.section.routes", defaultValue: "Routes the phone can dial"))
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
                Task { await store.reconnectOrRefresh() }
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
