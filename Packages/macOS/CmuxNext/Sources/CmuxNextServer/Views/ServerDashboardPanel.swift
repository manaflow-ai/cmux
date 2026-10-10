import SwiftUI

/// `dashboard`: a card per role with counts, and the pairing card.
struct DashboardPanel: View {
    let model: ServerModel
    let snapshot: ServerSnapshot
    @Environment(\.serverColors) private var colors

    var body: some View {
        let facts = PanelFacts(snapshot: snapshot, model: model)
        VStack(spacing: 8) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    RoleCard(symbol: "terminal", title: ServerStrings.terminals, value: "\(snapshot.terminals)",
                             state: snapshot.state(of: .session))
                    RoleCard(symbol: "square.stack.3d.up", title: ServerStrings.apps, value: facts.appsValue,
                             state: facts.appsTroubled ? .failed : snapshot.state(of: .apps))
                }
                GridRow {
                    RoleCard(symbol: "cylinder.split.1x2", title: ServerStrings.database, value: facts.databaseValue,
                             state: snapshot.state(of: .postgres),
                             usage: snapshot.databases.map(\.usage).max())
                    RoleCard(symbol: "globe", title: ServerStrings.browser, value: facts.browserValue,
                             state: snapshot.state(of: .browser))
                }
                GridRow {
                    RoleCard(symbol: "bolt.horizontal", title: ServerStrings.automations, value: "\(snapshot.automations)",
                             state: snapshot.state(of: .automations))
                    RoleCard(symbol: "heart.text.square", title: ServerStrings.health, value: facts.healthValue,
                             state: .on, tint: colors.severity(HealthOrdering.worst(facts.issues)), action: model.openHealth)
                }
            }
            PairingCard(model: model, pairing: snapshot.pairing)
        }
    }
}

struct RoleCard: View {
    let symbol: String
    let title: String
    let value: String
    let state: ServerRoleState
    var usage: Double?
    var tint: Color?
    var action: (() -> Void)?
    @State private var hovering = false
    @Environment(\.serverColors) private var colors

    var body: some View {
        let dim = state == .off || state == .unavailable
        let card = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(colors.secondary)
                Text(title).font(.system(size: 11.5)).foregroundStyle(colors.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if let dot = tint ?? stateColor { StateDot(color: dot, size: 6) }
            }
            Text(dim ? ServerStrings.state(state) : value)
                .font(.system(size: dim ? 14 : 20, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(dim ? colors.tertiary : colors.primary).lineLimit(1).minimumScaleFactor(0.7)
            if let usage, !dim {
                GeometryReader { proxy in
                    Capsule().fill(colors.hover).overlay(alignment: .leading) {
                        Capsule().fill(usage > 0.8 ? colors.warning : colors.secondary.opacity(0.6))
                            .frame(width: max(proxy.size.width * usage, 3))
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .card()
        .overlay(RoundedRectangle(cornerRadius: ServerMetrics.cardRadius, style: .continuous).fill(hovering && action != nil ? colors.hover.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        if let action { Button(action: action) { card }.buttonStyle(.plain) } else { card }
    }

    private var stateColor: Color? {
        switch state {
        case .failed: colors.critical
        case .starting: colors.warning
        default: nil
        }
    }
}

/// The pairing state as a full-width card: the live code, or team and owner.
struct PairingCard: View {
    let model: ServerModel
    let pairing: ServerPairingState
    @Environment(\.serverColors) private var colors

    var body: some View {
        HStack(spacing: 10) {
            switch pairing {
            case let .unpaired(offer?):
                QRCodeImage(payload: offer.qrPayload).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(offer.displayCode).font(.system(size: 18, weight: .semibold, design: .monospaced)).foregroundStyle(colors.primary)
                    Text(ServerStrings.expires(ServerFormat.time(offer.expiresAt))).font(.system(size: 11)).foregroundStyle(colors.tertiary)
                }
                Spacer()
            case .unpaired(nil):
                Image(systemName: "qrcode").foregroundStyle(colors.secondary)
                Text(ServerStrings.unpaired).font(.system(size: 12.5)).foregroundStyle(colors.secondary)
                Spacer()
                PillButton(title: ServerStrings.pairThisServer, action: model.showPairingCode)
            case .pairing:
                Image(systemName: "link").foregroundStyle(colors.secondary)
                Text(ServerStrings.pairing).font(.system(size: 12.5)).foregroundStyle(colors.secondary)
                Spacer()
            case let .paired(info):
                Image(systemName: "person.2").font(.system(size: 12)).foregroundStyle(colors.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "\(info.team) · \(info.owner)").font(.system(size: 12.5)).foregroundStyle(colors.primary)
                    Text(verbatim: info.hostID).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(colors.tertiary)
                }
                Spacer()
                Text(verbatim: "\(model.snapshot?.devices.count ?? 0)").font(.system(size: 12.5).monospacedDigit()).foregroundStyle(colors.secondary)
                Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 11)).foregroundStyle(colors.tertiary)
            }
        }
        .padding(10)
        .card()
    }
}
