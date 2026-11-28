import SwiftUI

/// One open alert: severity dot, check name, the server's title, Fix.
struct AlertRow: View {
    let model: ServerModel
    let alert: HealthAlert
    @Environment(\.serverColors) private var colors

    var body: some View {
        HoverRow {
            HStack(spacing: 8) {
                StateDot(color: colors.severity(alert.severity), size: 6).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ServerStrings.check(alert.check, fallback: alert.title))
                        .font(.system(size: 12.5)).foregroundStyle(colors.primary)
                    Text(alert.title).font(.system(size: 11)).foregroundStyle(colors.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                Spacer(minLength: 8)
                if let fix = alert.fix { FixButton(model: model, check: alert.check, fix: fix) }
            }
        }
    }
}
