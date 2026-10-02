import AppKit
import CmuxNextDesign
import SwiftUI

// Prototype layouts behind `agentActivity.layout` (Debug Settings).

/// "Lanes": one timeline across sessions, a lane per agent session, event
/// ticks on a shared time axis, the selected lane's frame below.
struct AgentActivityLanesView: View {
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
                        Rectangle().fill(Color(nsColor: Palette.separator)).frame(height: 1)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Rectangle().fill(Color(nsColor: Palette.separator)).frame(height: 1)
            if let session = model.selectedSession {
                HStack(spacing: 0) {
                    AgentActivityFramePreview(model: model, session: session).padding(12)
                    Rectangle().fill(Color(nsColor: Palette.separator)).frame(width: 1)
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
                        .foregroundStyle(Color(nsColor: Palette.textSecondary))
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
                            if let frame = event.displayFrame, event.kind == .act {
                                AgentActivityThumbnail(model: model, frame: frame, ok: event.ok, selected: false, hex: session.colorHex)
                                    .frame(height: 30)
                            } else {
                                Circle().fill(Color(nsColor: event.ok ? Palette.textTertiary : Palette.danger)).frame(width: 5, height: 5)
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
        .background(selected ? Color(nsColor: Palette.selectionFill) : .clear)
    }
}

/// "Grid": a wall of session tiles with the newest frame, for many agents
/// at once. A click selects; the bottom bar has the session controls.
struct AgentActivityGridView: View {
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
                Rectangle().fill(Color(nsColor: Palette.separator)).frame(height: 1)
                AgentActivityDetailHeader(model: model, session: session)
            }
        }
        .onAppear { model.follow(Set(sessions.map(\.id))) }
        .onDisappear { model.follow([]) }
    }
}

struct AgentActivityTile: View {
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
                    Rectangle().fill(Color(nsColor: Palette.hoverFill)).aspectRatio(1.6, contentMode: .fit)
                }
                if model.watching.contains(session.id) {
                    AgentActivityBadge(text: AgentActivityStrings.live, tint: Palette.danger).padding(6)
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
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
                Text(latest.map { "\($0.tool ?? "") · \($0.target ?? "")" } ?? session.targetApps.joined(separator: ", "))
                    .font(.system(size: 10)).lineLimit(1)
                    .foregroundStyle(Color(nsColor: Palette.textTertiary))
            }
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: Palette.elevatedBackground)))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(
            selected ? AgentActivityColor.color(hex: session.colorHex) : Color(nsColor: Palette.separator), lineWidth: selected ? 2 : 1))
        .opacity(session.status.isLive ? 1 : 0.7)
    }
}
