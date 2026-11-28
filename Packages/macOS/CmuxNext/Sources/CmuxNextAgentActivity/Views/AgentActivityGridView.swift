import AppKit
import SwiftUI

/// "Grid": a wall of session tiles with the newest frame, for many agents
/// at once. A click selects; the bottom bar has the session controls.
struct AgentActivityGridView: View {
    @Environment(\.agentActivityColors) private var colors
    let model: AgentActivityModel

    var body: some View {
        let sessions = model.groups.flatMap(\.sessions)
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 12)], spacing: 12) {
                    ForEach(sessions) { session in
                        AgentActivityTile(model: model, session: session, selected: session.id == model.selectedSessionID)
                            .onTapGesture { model.select(session: session.id) }
                    }
                }
                .padding(14)
            }
            if let session = model.selectedSession {
                Rectangle().fill(colors.separator).frame(height: 1)
                AgentActivityDetailHeader(model: model, session: session)
            }
        }
        .onAppear { model.follow(Set(sessions.map(\.id))) }
        .onDisappear { model.follow([]) }
    }
}

struct AgentActivityTile: View {
    @Environment(\.agentActivityColors) private var colors
    let model: AgentActivityModel
    let session: AgentActivitySession
    let selected: Bool

    var body: some View {
        let latest = (model.eventsBySession[session.id] ?? []).last { $0.displayFrame != nil }
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if let frame = latest?.displayFrame {
                    AgentActivityFrameImage(model: model, frame: frame)
                        .aspectRatio(CGFloat(frame.width) / CGFloat(max(frame.height, 1)), contentMode: .fit)
                } else {
                    Rectangle().fill(colors.hover).aspectRatio(1.6, contentMode: .fit)
                }
                if model.watching.contains(session.id) {
                    AgentActivityBadge(text: AgentActivityStrings.live, tint: colors.danger).padding(6)
                }
            }
            Rectangle().fill(AgentActivityColor.color(hex: session.colorHex)).frame(height: 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.agentName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Spacer()
                    AgentActivityStatusPill(status: session.status)
                }
                Text("\(session.machineName) · \(session.label)").font(.system(size: 10)).lineLimit(1)
                    .foregroundStyle(colors.secondary)
                Text(latest.map { "\($0.tool ?? "") · \($0.target ?? "")" } ?? session.targetApps.joined(separator: ", "))
                    .font(.system(size: 10)).lineLimit(1)
                    .foregroundStyle(colors.tertiary)
            }
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(colors.elevated))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(
            selected ? AgentActivityColor.color(hex: session.colorHex) : colors.separator, lineWidth: selected ? 2 : 1))
        .opacity(session.status.isLive ? 1 : 0.7)
    }
}
