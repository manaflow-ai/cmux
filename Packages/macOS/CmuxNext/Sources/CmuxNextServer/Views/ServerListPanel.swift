import SwiftUI

/// `list`: grouped list (apps, health, devices) with inline actions.
struct ListPanel: View {
    let model: ServerModel
    let snapshot: ServerSnapshot
    @Environment(\.serverColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ServerDivider().padding(.bottom, 2)
            if let offer = snapshot.pairing.offer {
                MetricRow(symbol: "qrcode", title: ServerStrings.pairThisServer, value: offer.displayCode)
            } else if case .unpaired(nil) = snapshot.pairing {
                MetricRow(symbol: "qrcode", title: ServerStrings.pairThisServer, value: "", action: model.showPairingCode)
            }
            MetricRow(symbol: "terminal", title: ServerStrings.terminals, value: "\(snapshot.terminals)")
            if !snapshot.appServers.isEmpty {
                GroupTitle(text: ServerStrings.apps)
                ForEach(snapshot.appServers) { AppServerRow(app: $0) }
            }
            GroupTitle(text: ServerStrings.health)
            let open = model.openAlerts
            if open.isEmpty {
                HoverRow(action: model.openHealth) {
                    HStack(spacing: 8) {
                        StateDot(color: colors.ok, size: 6).frame(width: 18)
                        Text(ServerStrings.allGood).font(.system(size: 12.5)).foregroundStyle(colors.secondary)
                        Spacer()
                    }
                }
            }
            ForEach(open) { AlertRow(model: model, alert: $0) }
            if !snapshot.devices.isEmpty {
                GroupTitle(text: ServerStrings.devices)
                ForEach(snapshot.devices) { DeviceRow(model: model, device: $0) }
            }
            ServerDivider().padding(.top, 4)
        }
    }
}

struct AppServerRow: View {
    let app: ServerAppServer
    @Environment(\.serverColors) private var colors

    var body: some View {
        HoverRow {
            HStack(spacing: 8) {
                StateDot(color: color, size: 6).frame(width: 18)
                Text(app.name).font(.system(size: 12.5)).foregroundStyle(app.holdsLease ? colors.primary : colors.secondary)
                if app.durability == .zeroLoss {
                    Image(systemName: "checkmark.icloud").font(.system(size: 10)).foregroundStyle(colors.tertiary)
                        .help(ServerStrings.zeroLoss)
                }
                Spacer(minLength: 8)
                Text(app.holdsLease ? ServerStrings.state(app.state) : ServerStrings.elsewhere)
                    .font(.system(size: 11.5)).foregroundStyle(app.state == .crashloop ? colors.critical : colors.tertiary)
            }
        }
    }

    private var color: Color {
        guard app.holdsLease else { return colors.tertiary.opacity(0.5) }
        switch app.state {
        case .running: return colors.ok
        case .starting, .draining: return colors.warning
        case .crashloop: return colors.critical
        case .stopped: return colors.tertiary
        }
    }
}

struct DeviceRow: View {
    let model: ServerModel
    let device: ServerDevice
    @State private var hovering = false
    @Environment(\.serverColors) private var colors

    var body: some View {
        HoverRow {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(colors.secondary).frame(width: 18)
                Text(device.name).font(.system(size: 12.5)).foregroundStyle(colors.primary)
                Spacer(minLength: 8)
                if hovering {
                    PillButton(title: ServerStrings.revoke) { model.revoke(device: device.id) }
                } else if let seen = device.lastSeen {
                    Text(ServerFormat.time(seen)).font(.system(size: 11).monospacedDigit()).foregroundStyle(colors.tertiary)
                }
            }
        }
        .onHover { hovering = $0 }
    }

    private var symbol: String {
        switch device.kind {
        case .mac: "laptopcomputer"
        case .phone: "iphone"
        case .web: "globe"
        case .cli: "terminal"
        }
    }
}
