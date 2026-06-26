func urgencyScore(_ ws: Workspace) -> Int {
  let downPenalty = ws.remote.connected ? 0 : 60
  let prPenalty = ws.pr.stale ? 25 : 0
  let dirtyPenalty = ws.dirty ? 8 : 0
  let pinBonus = ws.pinned ? 5 : 0
  return ws.unread * 4 + downPenalty + prPenalty + dirtyPenalty + pinBonus
}

func tier(_ score: Int) -> String {
  switch score {
  case 60...10000: return "critical"
  case 30...59: return "high"
  case 12...29: return "elevated"
  default: return "low"
  }
}

func tierColor(_ t: String) -> String {
  switch t {
  case "critical": return "#F7768E"
  case "high": return "#FF9E64"
  case "elevated": return "#E0AF68"
  default: return "#7AA2F7"
  }
}

func tierIcon(_ t: String) -> String {
  switch t {
  case "critical": return "exclamationmark.octagon.fill"
  case "high": return "exclamationmark.triangle.fill"
  case "elevated": return "bell.badge.fill"
  default: return "circle.dotted"
  }
}

func ago(_ at: Double) -> String {
  let d = clock.epoch - at
  if d < 60 { return "now" }
  if d < 3600 { return "\(Int(d / 60))m ago" }
  if d < 86400 { return "\(Int(d / 3600))h ago" }
  return "\(Int(d / 86400))d ago"
}

func remoteLabel(_ ws: Workspace) -> String {
  if ws.remote.connected { return ws.remote.target }
  return "\(ws.remote.target) DOWN"
}

func chip(_ icon: String, _ label: String, _ tint: String) -> some View {
  HStack(spacing: 4) {
    Image(systemName: icon).font(.system(size: 9)).foregroundColor(tint)
    Text(label).font(.system(size: 10)).fontWeight(.semibold).foregroundColor(tint).lineLimit(1)
  }
  .padding(.horizontal, 6)
  .padding(.vertical, 3)
  .background("#16161E")
  .cornerRadius(6)
  .overlay(Capsule().stroke(tint, lineWidth: 0.5).opacity(0.45))
}

func accentBar(_ tint: String, _ intensity: Double) -> some View {
  RoundedRectangle(cornerRadius: 3)
    .fill(LinearGradient(colors: [tint, "#16161E"], startPoint: .top, endPoint: .bottom))
    .frame(width: 4)
    .overlay(
      RoundedRectangle(cornerRadius: 3).stroke(tint, lineWidth: 0.5).opacity(0.6)
    )
    .opacity(0.55 + 0.45 * intensity)
}

let scored = workspaces.map { $0 }.sorted { urgencyScore($0) > urgencyScore($1) }
let needsAttention = scored.filter { urgencyScore($0) >= 12 }
let downCount = workspaces.filter { !$0.remote.connected }.count
let staleCount = workspaces.filter { $0.pr.stale }.count
let topScore = max(1, needsAttention.map { urgencyScore($0) }.reduce(0) { max($0, $1) })
let headerAccent = downCount > 0 ? "#F7768E" : unreadTotal >= 10 ? "#FF9E64" : unreadTotal > 0 ? "#E0AF68" : "#9ECE6A"

ScrollView {
  LazyVStack(alignment: .leading, spacing: 11) {

    ForEach(needsAttention) { ws in
      let score = urgencyScore(ws)
      let t = tier(score)
      let tint = tierColor(t)
      let intensity = Double(score) / Double(topScore)

      HStack(alignment: .top, spacing: 9) {
        accentBar(tint, intensity)

        VStack(alignment: .leading, spacing: 7) {

          HStack(spacing: 6) {
            Image(systemName: tierIcon(t))
              .font(.system(size: 12))
              .foregroundColor(tint)
              .symbolRenderingMode(.hierarchical)
            Text(ws.title)
              .font(.system(size: 13))
              .fontWeight(.semibold)
              .foregroundColor(ws.selected ? "#C0CAF5" : "#A9B1D6")
              .lineLimit(1)
            if ws.pinned {
              Image(systemName: "pin.fill").font(.system(size: 8)).foregroundColor("#E0AF68").rotationEffect(.degrees(40))
            }
            Spacer(minLength: 4)
            Text(t)
              .font(.system(size: 8))
              .fontWeight(.bold)
              .textCase(.uppercase)
              .foregroundColor(tint)
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(tint)
              .opacity(0.9)
              .background("#1A1B26")
              .cornerRadius(5)
              .foregroundColor("#1A1B26")
          }

          ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
              chip("bell.fill", "\(ws.unread) unread", tint)
              chip(ws.remote.connected ? "antenna.radiowaves.left.and.right" : "wifi.slash", remoteLabel(ws), ws.remote.connected ? "#7AA2F7" : "#F7768E")
              if ws.pr.stale { chip("clock.badge.exclamationmark", "PR #\(ws.pr.number) stale", "#FF9E64") }
              if ws.dirty { chip("pencil.line", ws.branch, "#E0AF68") }
              Spacer(minLength: 0)
            }
            HStack(spacing: 5) {
              chip("bell.fill", "\(ws.unread)", tint)
              chip(ws.remote.connected ? "antenna.radiowaves.left.and.right" : "wifi.slash", ws.remote.connected ? "up" : "down", ws.remote.connected ? "#7AA2F7" : "#F7768E")
              if ws.pr.stale { chip("clock.badge.exclamationmark", "#\(ws.pr.number)", "#FF9E64") }
              Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
              chip("bell.fill", "\(ws.unread)", tint)
              if !ws.remote.connected { Image(systemName: "wifi.slash").font(.system(size: 10)).foregroundColor("#F7768E") }
              Spacer(minLength: 0)
            }
          }

          if let msg = ws.latestMessage {
            HStack(alignment: .top, spacing: 6) {
              RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: [tint, tint, "#16161E"], startPoint: .top, endPoint: .bottom))
                .frame(width: 3)
              VStack(alignment: .leading, spacing: 2) {
                Text(msg)
                  .font(.system(size: 11))
                  .foregroundColor(ws.selected ? "#C0CAF5" : .secondary)
                  .lineLimit(2)
                  .truncationMode(.tail)
                  .multilineTextAlignment(.leading)
                Text(ago(ws.latestAt))
                  .font(.system(size: 9))
                  .fontDesign(.monospaced)
                  .foregroundColor(.tertiary)
              }
              Spacer(minLength: 0)
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background("#16161E")
            .cornerRadius(8)
          } else {
            HStack(spacing: 5) {
              Image(systemName: "text.bubble").font(.system(size: 9)).foregroundColor(.tertiary)
              Text("no recent message").font(.system(size: 10)).italic().foregroundColor(.tertiary)
              Spacer(minLength: 0)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background("#16161E")
            .cornerRadius(8)
          }

          HStack(spacing: 6) {
            Button { cmux("workspace.select", workspace_id: ws.id) } label: {
              HStack(spacing: 4) {
                Image(systemName: "arrow.right.circle.fill").font(.system(size: 10))
                Text("Triage").font(.system(size: 11)).fontWeight(.semibold)
              }
              .padding(.vertical, 5)
              .frame(maxWidth: .infinity)
              .background(LinearGradient(colors: [tint, tierColor(tier(score / 2))], startPoint: .leading, endPoint: .trailing))
              .foregroundColor("#1A1B26")
              .cornerRadius(7)
            }
            .keyboardShortcut(.return)
            Button { cmux("workspace.markRead", workspace_id: ws.id) } label: {
              Image(systemName: "checkmark.circle").font(.system(size: 12)).foregroundColor(.secondary)
                .padding(5).background("#1F2335").cornerRadius(7)
            }
            .help("Mark read")
            if ws.pr.number > 0 {
              Menu("PR") {
                Button("Open #\(ws.pr.number)") { cmux("pr.open", url: ws.pr.url) }
                Button("Copy branch") { cmux("workspace.copyBranch", workspace_id: ws.id) }
              }
              .font(.system(size: 10))
            }
          }
        }
      }
      .padding(9)
      .background("#1A1B26")
      .cornerRadius(12)
      .overlay(
        RoundedRectangle(cornerRadius: 12).stroke(tint, lineWidth: ws.selected ? 1.5 : 1).opacity(ws.selected ? 0.9 : 0.3)
      )
      .shadow(color: tint, radius: t == "critical" ? 7 : 0, x: 0, y: 1)
      .onTapGesture { cmux("workspace.select", workspace_id: ws.id) }
      .contextMenu {
        Button("Triage") { cmux("workspace.select", workspace_id: ws.id) }
        Button("Mark read") { cmux("workspace.markRead", workspace_id: ws.id) }
        Button(ws.pinned ? "Unpin" : "Pin") { cmux("workspace.togglePin", workspace_id: ws.id) }
      }
    }

    if needsAttention.count == 0 {
      VStack(spacing: 8) {
        Image(systemName: "checkmark.shield.fill").font(.system(size: 30)).foregroundColor("#9ECE6A").symbolRenderingMode(.hierarchical)
        Text("Nothing needs you").font(.system(size: 14)).fontWeight(.semibold).foregroundColor("#9ECE6A")
        Text("All \(workspaceCount) workspaces are calm: no unread, remotes up, PRs fresh.")
          .font(.system(size: 11)).foregroundColor(.secondary).multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
      .padding(22)
      .background("#16161E")
      .cornerRadius(12)
    }
  }
  .padding(10)
}
.safeAreaInset(edge: .top) {
  VStack(spacing: 8) {
    HStack(spacing: 10) {
      ZStack {
        Circle().stroke("#1F2335", lineWidth: 4).frame(width: 40, height: 40)
        Circle()
          .trim(from: 0, to: min(1.0, Double(unreadTotal) / Double(max(1, workspaceCount * 3))))
          .stroke(headerAccent, lineWidth: 4)
          .frame(width: 40, height: 40)
          .rotationEffect(.degrees(-90))
        Text("\(unreadTotal)").font(.system(size: 14)).fontWeight(.bold).foregroundColor(headerAccent).monospacedDigit()
      }
      VStack(alignment: .leading, spacing: 1) {
        Text("Needs attention").font(.system(size: 13)).fontWeight(.semibold).foregroundColor("#C0CAF5")
        Text(needsAttention.count == 0 ? "all clear" : "\(needsAttention.count) of \(workspaceCount) flagged")
          .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
      }
      Spacer()
      Text("\(clock.hour):\(clock.minute < 10 ? "0" : "")\(clock.minute)")
        .font(.system(size: 10)).fontDesign(.monospaced).foregroundColor(.secondary)
    }
    HStack(spacing: 5) {
      chip("envelope.badge.fill", "\(unreadTotal) unread", unreadTotal > 0 ? "#E0AF68" : "#565F89")
      chip("wifi.slash", "\(downCount) down", downCount > 0 ? "#F7768E" : "#565F89")
      chip("clock.badge.exclamationmark", "\(staleCount) stale", staleCount > 0 ? "#FF9E64" : "#565F89")
      Spacer()
    }
    ProgressView(value: Double(workspaceCount - needsAttention.count), total: Double(max(1, workspaceCount)))
      .tint("#9ECE6A")
  }
  .padding(10)
  .background {
    ZStack {
      Color("#16161E")
      LinearGradient(colors: [headerAccent, "#16161E"], startPoint: .top, endPoint: .bottom).opacity(0.1)
    }
  }
  .overlay(alignment: .bottom) {
    Rectangle().fill(headerAccent).frame(height: 1).opacity(0.4)
  }
}