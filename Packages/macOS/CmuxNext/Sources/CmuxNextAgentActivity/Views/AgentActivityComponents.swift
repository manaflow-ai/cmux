import AppKit
import CmuxNextDesign
import SwiftUI

/// The session's cursor color; a ring when the session is live.
struct AgentActivityChip: View {
    let hex: String
    let live: Bool

    var body: some View {
        Circle()
            .fill(AgentActivityColor.color(hex: hex))
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(AgentActivityColor.color(hex: hex).opacity(live ? 0.35 : 0), lineWidth: 3).padding(-2.5))
    }
}

struct AgentActivityStatusPill: View {
    let status: AgentActivityStatus

    var body: some View {
        Text(AgentActivityStrings.status(status))
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(fill))
            .foregroundStyle(foreground)
    }

    private var fill: Color {
        switch status {
        case .active: Color(nsColor: Palette.success).opacity(0.16)
        case .paused: Color(nsColor: Palette.attention).opacity(0.18)
        case .idle, .ended: Color(nsColor: Palette.badgeFill)
        }
    }

    private var foreground: Color {
        switch status {
        case .active: Color(nsColor: Palette.success)
        case .paused: Color(nsColor: Palette.attention)
        case .ended(.userStop): Color(nsColor: Palette.danger)
        case .idle, .ended: Color(nsColor: Palette.textSecondary)
        }
    }
}

struct AgentActivityBadge: View {
    let text: String
    var tint: NSColor? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(tint.map { Color(nsColor: $0).opacity(0.16) } ?? Color(nsColor: Palette.badgeFill)))
            .foregroundStyle(Color(nsColor: tint ?? Palette.textSecondary))
    }
}

struct AgentActivityCount: View {
    let symbol: String
    let value: Int
    var tint: NSColor = Palette.textTertiary

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
            Text("\(value)").monospacedDigit()
        }
        .font(.system(size: 10))
        .foregroundStyle(Color(nsColor: tint))
    }
}

struct AgentActivityToolbarButton: View {
    let title: String
    let symbol: String
    var tint: NSColor? = nil
    var on: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: on ? Palette.selectionFill : Palette.hoverFill)))
                .foregroundStyle(Color(nsColor: tint ?? Palette.textPrimary))
        }
        .buttonStyle(.plain)
    }
}

struct AgentActivityClickMarker: View {
    let hex: String

    var body: some View {
        ZStack {
            Circle().stroke(AgentActivityColor.color(hex: hex), lineWidth: 2).frame(width: 22, height: 22)
            Circle().fill(AgentActivityColor.color(hex: hex)).frame(width: 6, height: 6)
        }
        .shadow(color: .black.opacity(0.25), radius: 2)
    }
}

/// Loads a frame's pixels through the model (the source decodes off main).
struct AgentActivityFrameImage: View {
    let model: AgentActivityModel
    let frame: AgentActivityFrameRef
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: Palette.hoverFill))
            if let image {
                Image(nsImage: image).resizable().interpolation(.medium)
            }
        }
        .task(id: frame.blob) { image = await model.image(for: frame) }
    }
}

struct AgentActivityThumbnail: View {
    let model: AgentActivityModel
    let frame: AgentActivityFrameRef
    let ok: Bool
    let selected: Bool
    let hex: String

    var body: some View {
        AgentActivityFrameImage(model: model, frame: frame)
            .aspectRatio(CGFloat(frame.width) / CGFloat(max(frame.height, 1)), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(selected ? AgentActivityColor.color(hex: hex) : Color(nsColor: ok ? Palette.separator : Palette.danger),
                            lineWidth: selected ? 2 : 1)
            )
            .opacity(frame.expired ? 0.35 : 1)
    }
}

enum AgentActivityFormat {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    static func symbol(_ event: AgentActivityEvent) -> String {
        if !event.ok { return "exclamationmark.triangle.fill" }
        switch event.kind {
        case .sessionStart: return "play.circle"
        case .sessionEnd: return "checkmark.circle"
        case .sessionStop: return "stop.circle"
        case .sessionPause: return "pause.circle"
        case .sessionResume: return "play.circle"
        case .sessionIdle: return "moon"
        case .observe: return "eye"
        case .policyReject: return "hand.raised"
        case .consentRequest, .consentDecide: return "person.badge.shield.checkmark"
        case .error: return "exclamationmark.triangle"
        case .act:
            switch event.tool {
            case "type_text", "set_value": return "keyboard"
            case "press_key", "hotkey": return "command"
            case "scroll": return "scroll"
            case "drag": return "hand.draw"
            default: return "cursorarrow.click"
            }
        }
    }
}
