import AppKit
import SwiftUI

struct AgentActivitySplitView: View {
    @Environment(\.agentActivityColors) private var colors
    let model: AgentActivityModel

    var body: some View {
        HStack(spacing: 0) {
            AgentActivitySessionList(model: model)
                .frame(width: 300)
                .background(colors.sidebar)
            Rectangle().fill(colors.separator).frame(width: 1)
            if let session = model.selectedSession {
                AgentActivityDetailView(model: model, session: session)
            } else {
                Text(AgentActivityStrings.selectSession)
                    .foregroundStyle(colors.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct AgentActivitySessionList: View {
    @Environment(\.agentActivityColors) private var colors
    @Bindable var model: AgentActivityModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(colors.tertiary)
                TextField(AgentActivityStrings.filter, text: $model.filter).textFieldStyle(.plain)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(colors.hover))
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
    @Environment(\.agentActivityColors) private var colors
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
            .foregroundStyle(colors.secondary)
            if let notice = AgentActivityStrings.connection(group.connection) {
                Text(notice).font(.system(size: 10)).foregroundStyle(colors.attention)
            }
        }
        .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.sidebar)
    }
}
