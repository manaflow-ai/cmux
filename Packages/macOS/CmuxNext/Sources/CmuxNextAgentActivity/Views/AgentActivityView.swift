import AppKit
import CmuxNextDesign
import SwiftUI

/// Root of the pane. The layout comes from the Debug Settings prototype
/// switch (`agentActivity.layout`); Release always shows `split`.
struct AgentActivityView: View {
    let model: AgentActivityModel
    var layout: AgentActivityLayout = AgentActivityTunables.layout.value

    var body: some View {
        Group {
            if model.allSessions.isEmpty && model.connections.isEmpty {
                AgentActivityEmptyView()
            } else {
                switch layout {
                case .split: AgentActivitySplitView(model: model)
                case .timeline: AgentActivityLanesView(model: model)
                case .grid: AgentActivityGridView(model: model)
                }
            }
        }
        .background(Color(nsColor: Palette.contentBackground))
        .foregroundStyle(Color(nsColor: Palette.textPrimary))
    }
}

struct AgentActivityEmptyView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color(nsColor: Palette.textTertiary))
            Text(AgentActivityStrings.emptyTitle).font(.system(size: 15, weight: .semibold))
            Text(AgentActivityStrings.emptyDetail)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Split layout

struct AgentActivitySplitView: View {
    let model: AgentActivityModel

    var body: some View {
        HStack(spacing: 0) {
            AgentActivitySessionList(model: model)
                .frame(width: 300)
                .background(Color(nsColor: Palette.sidebarBackground))
            Rectangle().fill(Color(nsColor: Palette.separator)).frame(width: 1)
            if let session = model.selectedSession {
                AgentActivityDetailView(model: model, session: session)
            } else {
                Text(AgentActivityStrings.selectSession)
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct AgentActivitySessionList: View {
    @Bindable var model: AgentActivityModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(Color(nsColor: Palette.textTertiary))
                TextField(AgentActivityStrings.filter, text: $model.filter).textFieldStyle(.plain)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: Palette.hoverFill)))
            .padding(10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.groups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                AgentActivitySessionRow(session: session, selected: session.id == model.selectedSessionID)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.select(session: session.id) }
                            }
                        } header: {
                            AgentActivityMachineHeader(group: group)
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
            }
        }
    }
}

struct AgentActivityMachineHeader: View {
    let group: AgentActivityMachineGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: group.id == AgentActivityModel.localMachine ? "laptopcomputer" : "server.rack")
                Text(group.name).font(.system(size: 11, weight: .semibold))
                Spacer()
                let live = group.sessions.filter(\.status.isLive).count
                if live > 0 { Text("\(live)").font(.system(size: 10, weight: .semibold).monospacedDigit()) }
            }
            .foregroundStyle(Color(nsColor: Palette.textSecondary))
            if let notice = AgentActivityStrings.connection(group.connection) {
                Text(notice).font(.system(size: 10)).foregroundStyle(Color(nsColor: Palette.attention))
            }
        }
        .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: Palette.sidebarBackground))
    }
}

struct AgentActivitySessionRow: View {
    let session: AgentActivitySession
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            AgentActivityChip(hex: session.colorHex, live: session.status.isLive).padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.agentName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(AgentActivityFormat.relative(session.lastActionAt))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Color(nsColor: Palette.textTertiary))
                }
                Text(session.label).font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
                Text([session.workspaceTitle, session.terminalTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10)).lineLimit(1)
                    .foregroundStyle(Color(nsColor: Palette.textTertiary))
                HStack(spacing: 5) {
                    AgentActivityStatusPill(status: session.status)
                    if let badge = AgentActivityStrings.attribution(session.attribution) {
                        AgentActivityBadge(text: badge)
                    }
                    Spacer(minLength: 0)
                    AgentActivityCount(symbol: "cursorarrow.click", value: session.acts)
                    if session.errors > 0 {
                        AgentActivityCount(symbol: "exclamationmark.triangle", value: session.errors, tint: Palette.danger)
                    }
                }
                Text(session.targetApps.joined(separator: ", "))
                    .font(.system(size: 10)).lineLimit(1)
                    .foregroundStyle(Color(nsColor: Palette.textTertiary))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color(nsColor: Palette.selectionFill) : .clear))
    }
}

// MARK: Detail (preview, filmstrip, events)

struct AgentActivityDetailView: View {
    let model: AgentActivityModel
    let session: AgentActivitySession

    var body: some View {
        VStack(spacing: 0) {
            AgentActivityDetailHeader(model: model, session: session)
            Rectangle().fill(Color(nsColor: Palette.separator)).frame(height: 1)
            AgentActivityFramePreview(model: model, session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
            AgentActivityFilmstrip(model: model, session: session)
                .frame(height: AgentActivityTunables.filmstripHeight.value)
            Rectangle().fill(Color(nsColor: Palette.separator)).frame(height: 1)
            AgentActivityEventList(model: model)
                .frame(height: 170)
        }
        .focusable()
        .onKeyPress(.leftArrow, phases: .down) { press in
            model.step(-1, framesOnly: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(.rightArrow, phases: .down) { press in
            model.step(1, framesOnly: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(.home) { model.scrubToStart(); return .handled }
        .onKeyPress(.end) { model.scrubToEnd(); return .handled }
    }
}

struct AgentActivityDetailHeader: View {
    let model: AgentActivityModel
    let session: AgentActivitySession

    var body: some View {
        HStack(spacing: 10) {
            AgentActivityChip(hex: session.colorHex, live: session.status.isLive)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(session.agentName) · \(session.label)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text([session.machineName, session.workspaceTitle, session.terminalTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
            }
            AgentActivityStatusPill(status: session.status)
            if session.foregroundOnly { AgentActivityBadge(text: AgentActivityStrings.foregroundOnly) }
            Spacer()
            if session.status.isLive {
                let watching = model.watching.contains(session.id)
                AgentActivityToolbarButton(title: AgentActivityStrings.watch, symbol: watching ? "eye.fill" : "eye", on: watching) {
                    model.perform(.watch(session: session.id, on: !watching))
                }
                if session.status == .paused {
                    AgentActivityToolbarButton(title: AgentActivityStrings.resume, symbol: "play.fill") { model.perform(.resume(session: session.id)) }
                } else {
                    AgentActivityToolbarButton(title: AgentActivityStrings.pause, symbol: "pause.fill") { model.perform(.pause(session: session.id)) }
                }
                AgentActivityToolbarButton(title: AgentActivityStrings.stop, symbol: "stop.fill", tint: Palette.danger) {
                    model.perform(.stop(session: session.id))
                }
            }
            Menu {
                Button(AgentActivityStrings.openAgent) { model.perform(.openAgent(session: session.id)) }
                Button(AgentActivityStrings.openTarget) { model.perform(.openTarget(session: session.id)) }
                Button(AgentActivityStrings.export) { model.perform(.export(session: session.id)) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct AgentActivityFramePreview: View {
    let model: AgentActivityModel
    let session: AgentActivitySession

    var body: some View {
        let event = model.currentFrameEvent
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: Palette.elevatedBackground))
            if let event, let frame = event.displayFrame, !frame.expired {
                AgentActivityFrameImage(model: model, frame: frame)
                    .aspectRatio(CGFloat(frame.width) / CGFloat(max(frame.height, 1)), contentMode: .fit)
                    .overlay {
                        GeometryReader { proxy in
                            if let point = event.clickPoint {
                                AgentActivityClickMarker(hex: session.colorHex)
                                    .position(x: point.x * proxy.size.width, y: point.y * proxy.size.height)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: Color(nsColor: Palette.shadow), radius: 8, y: 2)
                    .padding(12)
            } else {
                Text(event?.displayFrame?.expired == true ? AgentActivityStrings.frameExpired : AgentActivityStrings.noFrame)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
            }
            if model.watching.contains(session.id) {
                VStack {
                    HStack {
                        Spacer()
                        AgentActivityBadge(text: AgentActivityStrings.live, tint: Palette.danger)
                    }
                    Spacer()
                }
                .padding(10)
            }
        }
    }
}

struct AgentActivityFilmstrip: View {
    let model: AgentActivityModel
    let session: AgentActivitySession

    var body: some View {
        let current = model.currentEvent?.seq
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(model.selectedEvents.filter { $0.displayFrame != nil }) { event in
                        if let frame = event.displayFrame {
                            AgentActivityThumbnail(model: model, frame: frame, ok: event.ok,
                                                   selected: event.seq == current, hex: session.colorHex)
                                .id(event.seq)
                                .onTapGesture { model.scrub(to: event.seq) }
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .onChange(of: current) { _, seq in
                if let seq { reader.scrollTo(seq, anchor: .center) }
            }
        }
    }
}

struct AgentActivityEventList: View {
    let model: AgentActivityModel

    var body: some View {
        let current = model.currentEvent?.seq
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.selectedEvents.reversed()) { event in
                        AgentActivityEventRow(event: event, selected: event.seq == current)
                            .id(event.seq)
                            .contentShape(Rectangle())
                            .onTapGesture { model.scrub(to: event.seq) }
                    }
                }
            }
            .onChange(of: current) { _, seq in
                if let seq { reader.scrollTo(seq, anchor: .center) }
            }
        }
    }
}

struct AgentActivityEventRow: View {
    let event: AgentActivityEvent
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(AgentActivityFormat.time(event.time))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color(nsColor: Palette.textTertiary))
                .frame(width: 58, alignment: .leading)
            Image(systemName: AgentActivityFormat.symbol(event))
                .foregroundStyle(Color(nsColor: event.ok ? Palette.textSecondary : Palette.danger))
                .frame(width: 14)
            Text(event.tool ?? event.kind.rawValue).font(.system(size: 11, weight: .medium, design: .monospaced))
            if let length = event.redactedTextLength {
                AgentActivityBadge(text: "\(AgentActivityStrings.typedTextHidden) · \(length)")
            }
            Text(event.target ?? "").font(.system(size: 11)).lineLimit(1)
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
            Spacer(minLength: 6)
            if let code = event.errorCode {
                Text(code).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(nsColor: Palette.danger))
            }
            if let ms = event.durationMs {
                Text("\(ms) ms").font(.system(size: 10).monospacedDigit()).foregroundStyle(Color(nsColor: Palette.textTertiary))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .background(selected ? Color(nsColor: Palette.selectionFill) : .clear)
    }
}
