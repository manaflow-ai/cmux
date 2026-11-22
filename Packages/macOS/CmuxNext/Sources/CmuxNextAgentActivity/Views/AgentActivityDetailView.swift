import AppKit
import SwiftUI

struct AgentActivityDetailView: View {
    @Environment(\.agentActivityColors) private var colors
    let model: AgentActivityModel
    let session: AgentActivitySession

    var body: some View {
        VStack(spacing: 0) {
            AgentActivityDetailHeader(model: model, session: session)
            Rectangle().fill(colors.separator).frame(height: 1)
            AgentActivityFramePreview(model: model, session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
            AgentActivityFilmstrip(model: model, session: session)
                .frame(height: AgentActivityTunables.filmstripHeight.value)
            Rectangle().fill(colors.separator).frame(height: 1)
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
    @Environment(\.agentActivityColors) private var colors
    let model: AgentActivityModel
    let session: AgentActivitySession

    var body: some View {
        HStack(spacing: 10) {
            AgentActivityChip(hex: session.colorHex, live: session.status.isLive)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(session.agentName) · \(session.label)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text([session.machineName, session.workspaceTitle, session.terminalTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(colors.secondary)
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
                AgentActivityToolbarButton(title: AgentActivityStrings.stop, symbol: "stop.fill", tint: colors.danger) {
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
