import SwiftUI

/// `summary`: one status line, only the open issues.
struct HealthSummary: View {
    let model: ServerModel
    @Environment(\.serverColors) private var colors

    var body: some View {
        let open = model.openAlerts
        let worst = HealthOrdering.worst(open)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StateDot(color: colors.severity(worst == .info ? nil : worst), size: 9)
                Text(worst == nil || worst == .info ? ServerStrings.allGood : ServerStrings.attention)
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(colors.primary)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            ForEach(open) { alert in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        CheckGlyph(severity: alert.severity)
                        Text(alert.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(colors.primary)
                        Spacer(minLength: 6)
                        Text(ServerStrings.check(alert.check, fallback: "")).font(.system(size: 10.5)).foregroundStyle(colors.tertiary)
                    }
                    Text(alert.body).font(.system(size: 11.5)).foregroundStyle(colors.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 26)
                    if let fix = alert.fix {
                        HStack {
                            Spacer()
                            FixButton(model: model, check: alert.check, fix: fix)
                        }
                    }
                }
                .padding(10).card()
            }
        }
    }
}

/// `timeline`: alerts over time, newest first, with resolve markers.
struct HealthTimeline: View {
    let model: ServerModel
    @Environment(\.serverColors) private var colors
    @Environment(\.serverLineWidth) private var line

    var body: some View {
        let events = model.timeline
        VStack(alignment: .leading, spacing: 0) {
            if events.isEmpty {
                Text(ServerStrings.noAlerts).font(.system(size: 12.5)).foregroundStyle(colors.secondary).padding(8)
            }
            ForEach(Array(events.enumerated()), id: \.element.id) { index, alert in
                HStack(alignment: .top, spacing: 10) {
                    Text(ServerFormat.time(alert.resolvedAt ?? alert.raisedAt))
                        .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(colors.tertiary)
                        .frame(width: 64, alignment: .trailing).padding(.top, 2)
                    VStack(spacing: 0) {
                        Circle()
                            .fill(alert.isOpen ? colors.severity(alert.severity) : .clear)
                            .strokeBorder(alert.isOpen ? .clear : colors.ok.opacity(0.8), lineWidth: 1.5)
                            .frame(width: 9, height: 9).padding(.top, 4)
                        if index < events.count - 1 {
                            Rectangle().fill(colors.separator.opacity(line == 0 ? 0 : 1)).frame(width: 1)
                        }
                    }
                    .frame(width: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ServerStrings.check(alert.check, fallback: alert.title))
                            .font(.system(size: 12.5)).foregroundStyle(alert.isOpen ? colors.primary : colors.secondary)
                        Text(alert.title).font(.system(size: 11)).foregroundStyle(colors.secondary)
                        if let resolved = alert.resolvedAt {
                            Text(verbatim: "\(ServerStrings.resolved) · \(ServerFormat.time(alert.raisedAt))–\(ServerFormat.time(resolved))")
                                .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(colors.ok.opacity(0.85))
                        } else if let fix = alert.fix {
                            FixButton(model: model, check: alert.check, fix: fix).padding(.top, 3)
                        }
                    }
                    .padding(.bottom, 12)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }
        }
    }
}
