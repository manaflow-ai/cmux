import SwiftUI

struct VoiceHUDView: View {
    let state: VoiceInputState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: micIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: state.activity == .listening)
                    .frame(width: 20)
                Text(statusLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor)
                Spacer()
            }

            if !state.transcript.isEmpty {
                Text("\u{201C}\(state.transcript)\u{201D}")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !state.lastAction.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(state.lastAction)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if !state.aiReply.isEmpty {
                Text(state.aiReply)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .error(let msg) = state.activity {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 320)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 4)
    }

    private var micIcon: String {
        switch state.activity {
        case .idle: return "mic.slash"
        case .connecting: return "wifi"
        case .listening: return "mic.fill"
        case .processing: return "ellipsis.bubble"
        case .executing: return "bolt.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch state.activity {
        case .idle: return .secondary
        case .connecting: return .orange
        case .listening: return .red
        case .processing: return .blue
        case .executing: return .green
        case .error: return .red
        }
    }

    private var statusLabel: String {
        switch state.activity {
        case .idle: return "Voice Off"
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .processing: return "Processing…"
        case .executing: return "Executing…"
        case .error: return "Error"
        }
    }
}
