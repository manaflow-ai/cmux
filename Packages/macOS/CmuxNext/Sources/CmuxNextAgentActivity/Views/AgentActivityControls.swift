import AppKit
import SwiftUI

struct AgentActivityCount: View {
    @Environment(\.agentActivityColors) private var colors
    let symbol: String
    let value: Int
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
            Text("\(value)").monospacedDigit()
        }
        .font(.system(size: 10))
        .foregroundStyle(tint ?? colors.tertiary)
    }
}

struct AgentActivityToolbarButton: View {
    @Environment(\.agentActivityColors) private var colors
    let title: String
    let symbol: String
    var tint: Color? = nil
    var on: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? colors.selection : colors.hover))
                .foregroundStyle(tint ?? colors.primary)
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
