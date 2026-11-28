func hasWord(_ t, _ word) -> Bool {
  if t.hasPrefix(word) { return true }
  if t.contains(" \(word)") { return true }
  if t.contains("-\(word)") { return true }
  if t.contains("/\(word)") { return true }
  return false
}

func bugText(_ w) -> String {
  let branch = hasBranch(w) ? w.branch : ""
  let prompt = hasPrompt(w) ? w.latestPrompt : ""
  let desc = w.description != nil && w.description != "" ? w.description : ""
  return "\(w.title) \(branch) \(prompt) \(desc)".lowercased()
}

func hasBranch(_ w) -> Bool {
  return w.branch != nil && w.branch != ""
}

func hasPrompt(_ w) -> Bool {
  return w.latestPrompt != nil && w.latestPrompt != ""
}

func hasPR(_ w) -> Bool {
  return w.pr != nil && w.pr.label != nil && w.pr.label != ""
}

func hasProgress(_ w) -> Bool {
  return w.progress != nil && w.progress.value != nil
}

func hasLatestAt(_ w) -> Bool {
  return w.latestAt != nil && w.latestAt != ""
}

func isSevere(_ w) -> Bool {
  let t = bugText(w)
  if hasWord(t, "crash") || hasWord(t, "hang") || hasWord(t, "freeze") || hasWord(t, "frozen") || hasWord(t, "deadlock") || hasWord(t, "panic") || hasWord(t, "beachball") || hasWord(t, "unresponsive") { return true }
  if hasWord(t, "oom") || t.contains("out of memory") || t.contains("data loss") || hasWord(t, "corrupt") { return true }
  if hasWord(t, "urgent") || hasWord(t, "hotfix") || hasWord(t, "p0") || hasWord(t, "sev") { return true }
  return false
}

func isBug(_ w) -> Bool {
  if isSevere(w) { return true }
  let t = bugText(w)
  return hasWord(t, "bug") || hasWord(t, "fix") || hasWord(t, "issue") || hasWord(t, "regression") || hasWord(t, "broken")
}

func urgencyRank(_ w) -> Int {
  let base = isSevere(w) ? 100 : 0
  return base + w.unread
}

func laneOf(_ w) -> String {
  if hasPR(w) && w.pr.status != "open" { return "done" }
  if isBug(w) { return "urgent" }
  if hasPR(w) { return "review" }
  if w.dirty == true || hasProgress(w) || hasPrompt(w) { return "wip" }
  return "research"
}

func agoLabel(_ mins) -> String {
  if mins < 1 { return "now" }
  if mins < 60 { return "\(mins)m" }
  if mins < 1440 { return "\(mins / 60)h" }
  return "\(mins / 1440)d"
}

func laneHeader(_ icon, _ name, _ count, _ tint) -> some View {
  HStack(spacing: 6) {
    Image(systemName: icon).font(.system(size: 11)).foregroundColor(tint)
    Text(name).font(.system(size: 11)).fontWeight(.semibold).textCase(.uppercase).foregroundColor(tint)
    Text("\(count)").font(.system(size: 10, design: .monospaced)).foregroundColor(tint)
      .padding(3)
      .background { Capsule().foregroundColor(tint).opacity(0.18) }
    Spacer()
  }
  .padding(4)
}

func row(_ w, _ tint, _ nowEpoch) -> some View {
  Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
    HStack(alignment: .top, spacing: 7) {
      Capsule().frame(width: 3, height: 28).foregroundColor(w.selected ? tint : Color(red: 0.5, green: 0.5, blue: 0.5)).opacity(w.selected ? 1.0 : 0.25)
      VStack(alignment: .leading, spacing: 2) {
        Text(w.title)
          .font(.system(size: 12))
          .fontWeight(w.selected ? .semibold : .regular)
          .lineLimit(1).truncationMode(.tail)
        HStack(spacing: 5) {
          if isSevere(w) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundColor("#F7768E")
          }
          if hasPR(w) {
            Text(w.pr.label)
              .font(.system(size: 9, design: .monospaced))
              .foregroundColor(w.pr.stale == true ? .tertiary : tint)
          }
          if !hasPR(w) && hasBranch(w) {
            Text(w.branch).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
          }
          if w.dirty == true {
            Image(systemName: "pencil").font(.system(size: 8)).foregroundColor(.secondary)
          }
          if hasLatestAt(w) {
            Text(agoLabel((nowEpoch - w.latestAt) / 60)).font(.system(size: 9, design: .monospaced)).foregroundColor(.tertiary)
          }
        }
        if hasProgress(w) && w.progress.value < 1.0 {
          ProgressView(value: w.progress.value, total: 1.0).tint(tint)
        }
      }
      Spacer()
      if w.unread > 0 {
        Text("\(w.unread)")
          .font(.system(size: 9, design: .monospaced)).bold()
          .foregroundColor("#1A1A22")
          .padding(4)
          .background { Circle().foregroundColor("#E0AF68") }
      }
    }
    .padding(4)
    .background { RoundedRectangle(cornerRadius: 6).foregroundColor(w.selected ? tint : "#000000").opacity(w.selected ? 0.14 : 0.0) }
  }
}

func lane(_ ws, _ icon, _ name, _ tint, _ nowEpoch) -> some View {
  VStack(alignment: .leading, spacing: 2) {
    laneHeader(icon, name, ws.count, tint)
    if ws.count == 0 {
      Text("none").font(.system(size: 10)).foregroundColor(.tertiary).padding(4)
    }
    ForEach(ws.prefix(20)) { w in
      row(w, tint, nowEpoch)
    }
  }
}

VStack(alignment: .leading, spacing: 6) {
  HStack {
    Text("Status board").font(.system(size: 13)).bold()
    Spacer()
    Text(clock.time).font(.system(size: 10, design: .monospaced)).foregroundColor(.tertiary)
  }
  .padding(4)
  Divider()

  // Bound live renders so large workspace lists do not repeatedly classify every row each tick.
  let boardWorkspaces = workspaces.prefix(80)
  let urgent = boardWorkspaces.filter { laneOf($0) == "urgent" }.sorted { urgencyRank($0) > urgencyRank($1) }
  let review = boardWorkspaces.filter { laneOf($0) == "review" }.sorted { $0.unread > $1.unread }
  let wip = boardWorkspaces.filter { laneOf($0) == "wip" }.sorted { $0.unread > $1.unread }
  let research = boardWorkspaces.filter { laneOf($0) == "research" }.sorted { $0.unread > $1.unread }
  let done = boardWorkspaces.filter { laneOf($0) == "done" }

  lane(urgent, "exclamationmark.triangle.fill", "Urgent bugs", "#F7768E", clock.epoch)
  Divider()
  lane(review, "eye.fill", "In review", "#7AA2F7", clock.epoch)
  Divider()
  lane(wip, "hammer.fill", "In progress", "#E0AF68", clock.epoch)
  Divider()
  lane(research, "leaf.fill", "Research", "#9ECE6A", clock.epoch)

  if done.count > 0 {
    Divider()
    laneHeader("checkmark.circle.fill", "Done", done.count, "#565F89")
    ForEach(done.prefix(5)) { w in
      row(w, "#565F89", clock.epoch).opacity(0.55)
    }
  }
  Spacer()
}
