import SwiftUI

/// A small state dot.
struct StateDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// The overall state as text and color.
struct OverallLabel {
    let text: String
    let color: Color

    init(_ overall: ServerOverall, colors: ServerColors) {
        switch overall {
        case .unavailable: (text, color) = (ServerStrings.unreachable, colors.tertiary)
        case .off: (text, color) = (ServerStrings.off, colors.tertiary)
        case .unpaired: (text, color) = (ServerStrings.unpaired, colors.secondary)
        case .pairing: (text, color) = (ServerStrings.pairing, colors.secondary)
        case .serving: (text, color) = (ServerStrings.serving, colors.ok)
        case let .attention(severity): (text, color) = (ServerStrings.attention, colors.severity(severity))
        }
    }
}

/// Host name, overall state and the on/off switch: the top of every panel.
struct ServerHeader: View {
    let model: ServerModel
    @Environment(\.serverColors) private var colors

    var body: some View {
        let label = OverallLabel(model.overall, colors: colors)
        HStack(spacing: 10) {
            Image(systemName: model.snapshot?.platform == .macOS ? "macmini" : "server.rack")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(colors.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.snapshot?.hostName ?? ServerStrings.title)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.primary)
                HStack(spacing: 5) {
                    StateDot(color: label.color, size: 6)
                    Text(subtitle(label.text)).font(.system(size: 11.5)).foregroundStyle(colors.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let snapshot = model.snapshot {
                Toggle("", isOn: Binding(get: { snapshot.enabled }, set: { _ in model.toggleServer() }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .tint(colors.primary.opacity(0.75))
                    .disabled(model.isPending { if case .setEnabled = $0 { true } else { false } })
            }
        }
    }

    private func subtitle(_ state: String) -> String {
        guard case let .paired(pairing)? = model.snapshot?.pairing, model.snapshot?.enabled == true else { return state }
        return "\(state) · \(pairing.team)"
    }
}
