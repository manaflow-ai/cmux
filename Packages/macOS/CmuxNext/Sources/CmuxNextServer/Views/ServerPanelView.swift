import CmuxNextDesign
import SwiftUI

/// The menubar panel: one of three prototypes over the same model.
struct ServerPanelView: View {
    let model: ServerModel
    let style: ServerPanelStyle
    @Environment(\.serverColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ServerHeader(model: model).padding(.horizontal, 6)
            if let snapshot = model.snapshot {
                switch style {
                case .compact: CompactPanel(model: model, snapshot: snapshot)
                case .dashboard: DashboardPanel(model: model, snapshot: snapshot)
                case .list: ListPanel(model: model, snapshot: snapshot)
                }
                if let reject = model.lastReject {
                    Text(reject).font(.system(size: 11)).foregroundStyle(colors.critical).padding(.horizontal, 8)
                }
                StoreFooter(store: snapshot.store)
            }
            if let chief = model.chief { ChiefPlacementRow(status: chief) }
        }
        .padding(ServerMetrics.padding - 6)
        .padding(.vertical, 6)
        .frame(width: style == .dashboard ? ServerMetrics.dashboardWidth : ServerMetrics.panelWidth)
        .animation(reduceMotion ? nil : Motion.animation(.crossfade), value: model.snapshot)
    }
}

/// Values the panels share.
@MainActor
struct PanelFacts {
    let snapshot: ServerSnapshot
    let model: ServerModel

    var hosted: [ServerAppServer] { snapshot.appServers.filter(\.holdsLease) }
    var running: Int { hosted.filter { $0.state == .running }.count }
    var appsValue: String { hosted.isEmpty ? "–" : "\(running)/\(hosted.count)" }
    var appsTroubled: Bool { hosted.contains { $0.state == .crashloop } }
    var databaseValue: String { snapshot.databases.isEmpty ? "–" : ServerFormat.bytes(snapshot.databaseBytes) }
    /// Open warnings and criticals (info alerts do not count against health).
    var issues: [HealthAlert] { model.openAlerts.filter { $0.severity != .info } }
    var healthValue: String { issues.isEmpty ? ServerStrings.allGood : "\(issues.count)" }

    var browserValue: String {
        switch snapshot.browser {
        case .off: ServerStrings.off
        case .idle: "0"
        case let .running(pages): "\(pages)"
        case .unavailable: ServerStrings.state(ServerRoleState.unavailable)
        }
    }
}

/// `compact`: status line, switch, four rows.
struct CompactPanel: View {
    let model: ServerModel
    let snapshot: ServerSnapshot
    @Environment(\.serverColors) private var colors

    var body: some View {
        let facts = PanelFacts(snapshot: snapshot, model: model)
        VStack(spacing: 0) {
            ServerDivider().padding(.bottom, 4)
            MetricRow(symbol: "terminal", title: ServerStrings.terminals, value: "\(snapshot.terminals)")
            MetricRow(symbol: "square.stack.3d.up", title: ServerStrings.apps, value: facts.appsValue,
                      dot: facts.appsTroubled ? colors.critical : nil)
            MetricRow(symbol: "cylinder.split.1x2", title: ServerStrings.database, value: facts.databaseValue)
            MetricRow(symbol: "heart.text.square", title: ServerStrings.health, value: facts.healthValue,
                      dot: colors.severity(HealthOrdering.worst(facts.issues)), action: model.openHealth)
            if let offer = snapshot.pairing.offer {
                MetricRow(symbol: "qrcode", title: ServerStrings.pairThisServer, value: offer.displayCode)
            } else if case .unpaired(nil) = snapshot.pairing {
                MetricRow(symbol: "qrcode", title: ServerStrings.pairThisServer, value: "", action: model.showPairingCode)
            }
            ServerDivider().padding(.top, 4)
        }
    }
}
