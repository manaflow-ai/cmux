// Claude Code background agents, grouped by project (working directory).
//
// Binds to the live `agents` array (mirrors `claude agents --json --all`):
// every live session plus background sessions that are still working or
// blocked, and completed ones. A status dot encodes state, and the right side
// shows what a blocked session is waiting on plus its raw state.
VStack(alignment: .leading, spacing: 4) {
    Text("Claude Agents").font(.headline)
    Text("\(agentsWorkingCount) working · \(agentsBlockedCount) blocked · \(agentsCount) total")
        .font(.system(size: 10)).monospacedDigit().foregroundColor(.secondary)
    Divider()

    let sorted = agents.sorted { $0.cwd < $1.cwd }
    ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sorted.enumerated()), id: \.offset) { i, a in
                let parts = a.cwd.split(separator: "/")
                let proj = parts.count > 0 ? String(parts.last) : a.cwd
                let prevCwd = i > 0 ? sorted[i - 1].cwd : ""
                let showHeader = i == 0 || a.cwd != prevCwd
                let dot = a.working ? "#34C759" : (a.blocked ? "#FF9F0A" : (a.failed ? "#F85149" : "#8E8E93"))

                VStack(alignment: .leading, spacing: 0) {
                    if showHeader {
                        Text(proj)
                            .font(.system(size: 10)).bold().textCase(.uppercase)
                            .foregroundColor(.secondary)
                            .padding(.top, i == 0 ? 2 : 8)
                            .padding(.bottom, 2)
                    }
                    HStack(alignment: .center, spacing: 6) {
                        Text("●").font(.system(size: 7)).foregroundColor(dot)
                        Text(a.name != nil ? a.name : (a.id != nil ? a.id : "session"))
                            .font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        if a.waitingFor != nil {
                            Text(a.waitingFor)
                                .font(.system(size: 9)).foregroundColor("#FF9F0A")
                                .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                        }
                        if a.state != nil {
                            Text(a.state)
                                .font(.system(size: 9)).monospaced()
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 22, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
