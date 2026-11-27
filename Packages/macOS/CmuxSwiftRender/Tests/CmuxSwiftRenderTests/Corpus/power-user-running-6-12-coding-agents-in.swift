HSplitView {
  VStack(alignment: .leading, spacing: 10) {
    let cost = agents.reduce(0.0) { $0 + $1.costUSD }
    let need = agents.filter { $0.status == "approval" }.count
    HStack { Text("Agent Ops").font(.title2).bold(); Spacer(); Text(cost.formatted(.currency(code: "USD"))).foregroundColor("#E0AF68") }
    Text(need > 0 ? "\(need) need you" : "all clear").font(.caption).foregroundColor(need > 0 ? "#F7768E" : "#9ECE6A")
    Divider()
    ForEach(agents.flatMap { $0.approvals }) { req in
      VStack(alignment: .leading, spacing: 6) {
        HStack { Image(systemName: req.kind == "shell" ? "terminal.fill" : "doc.fill"); Text(req.agentTitle).font(.headline) }
        Text(req.summary).font(.system(.caption, design: .monospaced)).lineLimit(2)
        HStack {
          Button { cmux("agent.approve", request_id: req.id); log("ok") } label: { Text("Approve") }.background("#1F2335").foregroundColor("#9ECE6A").cornerRadius(8).keyboardShortcut(.return, modifiers: [])
          Button { cmux("agent.deny", request_id: req.id) } label: { Text("Deny") }.foregroundColor("#F7768E")
        }
      }.padding(10).background("#16161E").overlay(RoundedRectangle(cornerRadius: 10).stroke("#F7768E", lineWidth: 1)).cornerRadius(10)
    }
    Divider()
    ScrollView {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(agents.sorted { $0.statusRank < $1.statusRank }) { a in
          let dot = a.status == "approval" ? "#F7768E" : a.status == "idle" ? "#E0AF68" : a.status == "running" ? "#9ECE6A" : "#565F89"
          HStack {
            Image(systemName: "circle.fill").font(.caption2).foregroundColor(dot)
            VStack(alignment: .leading, spacing: 2) {
              HStack { Text(a.title).font(.headline).lineLimit(1); Spacer(); Text(a.costUSD.formatted(.currency(code: "USD"))).foregroundColor("#E0AF68") }
              HStack { Text(a.activity).font(.caption).foregroundColor(.gray).lineLimit(1); Spacer(); Text("\(a.tokens.formatted(.number.notation(.compactName)))").font(.caption2).foregroundColor("#BB9AF7") }
              if a.status == "idle" && a.idleSeconds > 120 { Text("idle on the clock").font(.caption2).foregroundColor("#E0AF68") }
            }
          }.padding(8).background(a.selected ? "#1F2335" : "#16161E").cornerRadius(8).onTapGesture { cmux("workspace.select", workspace_id: a.workspaceId) }.contextMenu { Button("Stop agent") { cmux("agent.stop", workspace_id: a.workspaceId) }; Button("Re-run") { cmux("agent.requeue", workspace_id: a.workspaceId) } }
        }
      }
    }
    Spacer()
  }.padding(12)
  VStack(alignment: .leading, spacing: 10) {
    HStack { Text("Task Queue").font(.title2).bold(); Spacer(); Button { cmux("task.new") } label: { Image(systemName: "plus.circle.fill").foregroundColor("#7AA2F7") } }
    ForEach(["running", "queued", "done"]) { g in
      let items = tasks.filter { $0.state == g }
      let tint = g == "running" ? "#9ECE6A" : g == "queued" ? "#7AA2F7" : "#565F89"
      Text("\(g) \(items.count)").font(.caption).fontWeight(.semibold).foregroundColor(tint)
      ForEach(items) { t in
        HStack {
          Image(systemName: t.state == "running" ? "play.fill" : t.state == "queued" ? "hourglass" : "checkmark").font(.caption).foregroundColor(tint)
          VStack(alignment: .leading, spacing: 2) {
            Text(t.title).font(.callout).lineLimit(1).strikethrough(t.state == "done")
            HStack { Text(t.agentTitle).font(.caption2).foregroundColor(.gray); Spacer(); Text(t.costUSD.formatted(.currency(code: "USD"))).font(.caption2).foregroundColor("#E0AF68") }
          }
          Spacer()
          if t.state == "running" { Button { cmux("task.stop", task_id: t.id) } label: { Image(systemName: "stop.fill").foregroundColor("#F7768E") } }
          else if t.state == "queued" { Button { cmux("task.promote", task_id: t.id) } label: { Image(systemName: "arrow.up.to.line").foregroundColor("#7AA2F7") } }
          else { Button { cmux("task.requeue", task_id: t.id) } label: { Image(systemName: "arrow.clockwise").foregroundColor("#7AA2F7") } }
        }.padding(8).background("#16161E").cornerRadius(8).opacity(t.state == "done" ? 0.55 : 1.0).onTapGesture { cmux("task.focus", task_id: t.id) }
      }
      Divider()
    }
    Spacer()
  }.padding(12)
}
