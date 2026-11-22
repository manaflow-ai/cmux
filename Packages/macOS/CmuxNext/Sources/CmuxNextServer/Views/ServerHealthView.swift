import CmuxNextDesign
import SwiftUI

/// Server health: one of three prototypes over the alert set.
struct ServerHealthView: View {
    let model: ServerModel
    let style: ServerHealthStyle
    @Environment(\.serverColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "heart.text.square").font(.system(size: 15)).foregroundStyle(colors.secondary)
                Text(ServerStrings.health).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.primary)
                if let host = model.snapshot?.hostName {
                    Text(verbatim: host).font(.system(size: 12)).foregroundStyle(colors.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            switch style {
            case .checklist: HealthChecklist(model: model)
            case .summary: HealthSummary(model: model)
            case .timeline: HealthTimeline(model: model)
            }
        }
        .padding(ServerMetrics.padding - 4)
        .padding(.vertical, 4)
        .frame(width: ServerMetrics.dashboardWidth)
        .animation(reduceMotion ? nil : Motion.animation(.crossfade), value: model.snapshot?.alerts)
    }
}

/// The glyph of a check: passing, or its open alert's severity.
struct CheckGlyph: View {
    let severity: HealthSeverity?
    @Environment(\.serverColors) private var colors

    var body: some View {
        Image(systemName: symbol).font(.system(size: 12, weight: .medium))
            .foregroundStyle(severity == nil ? colors.ok.opacity(0.8) : colors.severity(severity)).frame(width: 18)
    }

    private var symbol: String {
        switch severity {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        case nil: "checkmark.circle"
        }
    }
}

/// `checklist`: every check the server runs, with state and Fix.
struct HealthChecklist: View {
    let model: ServerModel
    @Environment(\.serverColors) private var colors

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.checklist) { row in
                HoverRow {
                    HStack(alignment: .center, spacing: 8) {
                        CheckGlyph(severity: row.alert?.severity)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ServerStrings.check(row.check, fallback: row.alert?.title ?? row.check.rawValue))
                                .font(.system(size: 12.5)).foregroundStyle(row.alert == nil ? colors.secondary : colors.primary)
                            if let alert = row.alert {
                                Text(alert.title).font(.system(size: 11)).foregroundStyle(colors.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, row.alert == nil ? 0 : 4)
                        Spacer(minLength: 8)
                        if let alert = row.alert, let fix = alert.fix {
                            FixButton(model: model, check: alert.check, fix: fix)
                        }
                    }
                }
            }
        }
    }
}
