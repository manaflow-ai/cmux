import AppKit
import SwiftUI

/// "Lanes": one timeline across sessions, a lane per agent session, event
/// ticks on a shared time axis, the selected lane's frame below.
struct AgentActivityLanesView: View {
    @Environment(\.agentActivityColors) private var colors
    let model: AgentActivityModel

    private var sessions: [AgentActivitySession] {
        model.groups.flatMap(\.sessions).filter { $0.status.isLive || $0.lastActionAt > Date().addingTimeInterval(-3600) }
    }

    var body: some View {
        let sessions = sessions
        let range = Self.timeRange(sessions)
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sessions) { session in
                        AgentActivityLane(model: model, session: session, range: range,
                                          selected: session.id == model.selectedSessionID)
                            .contentShape(Rectangle())
                            .onTapGesture { model.select(session: session.id) }
                        Rectangle().fill(colors.separator).frame(height: 1)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Rectangle().fill(colors.separator).frame(height: 1)
            if let session = model.selectedSession {
                HStack(spacing: 0) {
                    AgentActivityFramePreview(model: model, session: session).padding(12)
                    Rectangle().fill(colors.separator).frame(width: 1)
                    AgentActivityEventList(model: model).frame(width: 380)
                }
                .frame(height: 300)
            }
        }
        .onAppear { model.follow(Set(sessions.map(\.id))) }
        .onDisappear { model.follow([]) }
    }

    static func timeRange(_ sessions: [AgentActivitySession]) -> ClosedRange<Date> {
        let start = sessions.map(\.startedAt).min() ?? Date().addingTimeInterval(-600)
        let end = max(sessions.map(\.lastActionAt).max() ?? Date(), start.addingTimeInterval(60))
        return start...end
    }
}

struct AgentActivityLane: View {
    @Environment(\.agentActivityColors) private var colors
    let model: AgentActivityModel
    let session: AgentActivitySession
    let range: ClosedRange<Date>
    let selected: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                AgentActivityChip(hex: session.colorHex, live: session.status.isLive)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.agentName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text("\(session.machineName) · \(session.label)").font(.system(size: 10)).lineLimit(1)
                        .foregroundStyle(colors.secondary)
                }
                Spacer(minLength: 4)
                AgentActivityStatusPill(status: session.status)
            }
            .padding(.horizontal, 10)
            .frame(width: 260)
            GeometryReader { proxy in
                let events = model.eventsBySession[session.id] ?? []
                let span = max(range.upperBound.timeIntervalSince(range.lowerBound), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(AgentActivityColor.color(hex: session.colorHex).opacity(0.12))
                        .frame(width: max(4, proxy.size.width * session.lastActionAt.timeIntervalSince(session.startedAt) / span), height: 6)
                        .offset(x: proxy.size.width * session.startedAt.timeIntervalSince(range.lowerBound) / span)
                    ForEach(events) { event in
                        let x = proxy.size.width * event.time.timeIntervalSince(range.lowerBound) / span
                        Group {
                            if let frame = event.displayFrame, event.kind == .act, event.seq % 5 == 0 {
                                AgentActivityThumbnail(model: model, frame: frame, ok: event.ok, selected: false, hex: session.colorHex)
                                    .frame(height: 26)
                            } else {
                                Circle().fill(event.ok ? AgentActivityColor.color(hex: session.colorHex) : colors.danger).frame(width: 6, height: 6)
                            }
                        }
                        .position(x: x, y: proxy.size.height / 2)
                        .onTapGesture {
                            model.select(session: session.id)
                            model.scrub(to: event.seq)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.trailing, 24)
        }
        .frame(height: 54)
        .background(selected ? colors.selection : .clear)
    }
}
