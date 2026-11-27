func statusColor(_ w) -> String {
  if w.remote != nil && w.remote.connected == false { return "#F7768E" }
  if w.unread > 0 { return "#E0AF68" }
  if w.progress != nil && w.progress.value < 1.0 { return "#7AA2F7" }
  if w.dirty == true { return "#BB9AF7" }
  return "#9ECE6A"
}

func statusGlyph(_ w) -> String {
  if w.remote != nil && w.remote.connected == false { return "bolt.horizontal.circle.fill" }
  if w.unread > 0 { return "bell.badge.fill" }
  if w.progress != nil && w.progress.value < 1.0 { return "circle.dotted" }
  if w.dirty == true { return "pencil.circle.fill" }
  return "checkmark.circle.fill"
}

func statusLabel(_ w) -> String {
  if w.remote != nil && w.remote.connected == false { return "remote down" }
  if w.unread > 0 { return "\(w.unread) unread" }
  if w.progress != nil && w.progress.value < 1.0 { return w.progress.label }
  if w.dirty == true { return "uncommitted" }
  return "idle / clean"
}

func dot(_ hex, _ size) -> some View {
  Circle()
    .frame(width: size, height: size)
    .foregroundColor(hex)
    .overlay {
      Circle().stroke("#0D0D14", lineWidth: 1.5)
    }
    .shadow(radius: 4, x: 0, y: 0, color: hex)
}

func chip(_ icon, _ label, _ tint) -> some View {
  HStack(spacing: 4) {
    Image(systemName: icon).font(.system(size: 9)).foregroundColor(tint)
    Text(label).font(.system(size: 10, design: .monospaced)).foregroundColor(tint).lineLimit(1)
  }
  .padding(5)
  .background {
    Capsule().foregroundColor("#16161E").overlay { Capsule().stroke(tint, lineWidth: 0.75).opacity(0.4) }
  }
}

func card(_ w) -> some View {
  let accent = w.color != nil ? w.color : statusColor(w)
  let glyph = statusGlyph(w)
  let dotHex = statusColor(w)
  VStack(alignment: .leading, spacing: 8) {
    HStack(alignment: .top, spacing: 6) {
      Capsule().frame(width: 3, height: 30).foregroundColor(accent)
      VStack(alignment: .leading, spacing: 2) {
        Text(w.title).font(.system(size: 13)).fontWeight(.semibold).foregroundColor("#C0CAF5").lineLimit(1).truncationMode(.tail)
        HStack(spacing: 4) {
          Image(systemName: w.pinned ? "pin.fill" : "number").font(.system(size: 8)).foregroundColor(.tertiary)
          Text("ws \(w.index)").font(.system(size: 9, design: .monospaced)).foregroundColor(.tertiary)
          if w.tabCount > 0 {
            Text("· \(w.tabCount) tab").font(.system(size: 9, design: .monospaced)).foregroundColor(.tertiary)
          }
        }
      }
      Spacer()
    }

    if w.branch != nil {
      chip(w.dirty == true ? "arrow.triangle.branch" : "checkmark.seal", w.branch, w.dirty == true ? "#BB9AF7" : "#9ECE6A")
    }

    if w.progress != nil && w.progress.value < 1.0 {
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(w.progress.label).font(.system(size: 9)).foregroundColor("#7AA2F7").lineLimit(1)
          Spacer()
          Text("\(w.progress.value.formatted(.percent))").font(.system(size: 9, design: .monospaced)).foregroundColor("#7AA2F7")
        }
        ProgressView(value: w.progress.value, total: 1.0).tint("#7AA2F7")
      }
    }

    if w.latestMessage != nil {
      Text(w.latestMessage).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2).multilineTextAlignment(.leading)
    }

    HStack(spacing: 5) {
      if w.portCount > 0 {
        chip("network", "\(w.portCount) port", "#73DACA")
      }
      if w.pr != nil {
        chip("arrow.triangle.pull", "PR #\(w.pr.number)", w.pr.stale == true ? "#E0AF68" : "#7AA2F7")
      }
      Spacer()
      Text(statusLabel(w)).font(.system(size: 9)).foregroundColor(dotHex).lineLimit(1)
    }
  }
  .padding(11)
  .frame(maxWidth: .infinity, alignment: .leading)
  .background {
    RoundedRectangle(cornerRadius: 13)
      .foregroundColor(w.selected ? "#1A1B2E" : "#13131C")
      .overlay {
        RoundedRectangle(cornerRadius: 13).stroke(w.selected ? accent : "#272A3D", lineWidth: w.selected ? 1.5 : 1)
      }
  }
  .overlay(alignment: .topTrailing) {
    ZStack {
      dot(dotHex, 11)
      if w.unread > 0 {
        Text("\(min(w.unread, 99))")
          .font(.system(size: 9, design: .monospaced))
          .bold()
          .foregroundColor("#0D0D14")
          .padding(4)
          .frame(minWidth: 17)
          .background { Capsule().foregroundColor("#F7768E") }
          .offset(x: 13, y: -4)
      }
    }
    .overlay(alignment: .center) {
      Image(systemName: glyph)
        .font(.system(size: 9))
        .symbolRenderingMode(.hierarchical)
        .foregroundColor("#0D0D14")
        .opacity(0.0)
    }
    .offset(x: 5, y: -5)
  }
  .opacity(w.remote != nil && w.remote.connected == false ? 0.7 : 1.0)
  .onTapGesture { cmux("workspace.select", workspace_id: w.id) }
  .contextMenu {
    Button("Select") { cmux("workspace.select", workspace_id: w.id) }
    Button("Stop agent") { cmux("workspace.stop", workspace_id: w.id) }
    Button(w.pinned ? "Unpin" : "Pin") { cmux("workspace.pin", workspace_id: w.id) }
    if w.pr != nil {
      Button("Open PR") { cmux("workspace.openPR", workspace_id: w.id) }
    }
  }
  .help("\(w.title) — \(statusLabel(w))")
}

ScrollView {
  VStack(alignment: .leading, spacing: 12) {
    let dirtyCount = workspaces.filter { $0.dirty == true }.count
    let liveCount = workspaces.filter { $0.progress != nil && $0.progress.value < 1.0 }.count
    let downCount = workspaces.filter { $0.remote != nil && $0.remote.connected == false }.count

    HStack(alignment: .center, spacing: 8) {
      ZStack {
        RoundedRectangle(cornerRadius: 9).frame(width: 32, height: 32).foregroundColor("#1A1B2E")
        Image(systemName: "antenna.radiowaves.left.and.right")
          .font(.system(size: 15))
          .symbolRenderingMode(.hierarchical)
          .foregroundColor("#7AA2F7")
      }
      VStack(alignment: .leading, spacing: 1) {
        Text("Control Room").font(.system(size: 15)).bold().foregroundColor("#C0CAF5")
        Text("\(workspaceCount) workspaces").font(.system(size: 10, design: .monospaced)).foregroundColor(.tertiary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 1) {
        Text("\(clock.time)").font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
        if unreadTotal > 0 {
          Text("\(unreadTotal) unread").font(.system(size: 9, design: .monospaced)).foregroundColor("#F7768E")
        } else {
          Text("all read").font(.system(size: 9, design: .monospaced)).foregroundColor("#9ECE6A")
        }
      }
    }

    HStack(spacing: 6) {
      chip("dot.radiowaves.up.forward", "\(liveCount) live", "#7AA2F7")
      chip("pencil", "\(dirtyCount) dirty", "#BB9AF7")
      if downCount > 0 {
        chip("bolt.slash", "\(downCount) down", "#F7768E")
      } else {
        chip("checkmark.shield", "all up", "#9ECE6A")
      }
      Spacer()
    }

    Divider().background("#272A3D")

    if workspaceCount == 0 {
      VStack(spacing: 8) {
        Image(systemName: "tray").font(.system(size: 28)).foregroundColor(.tertiary).symbolRenderingMode(.hierarchical)
        Text("No workspaces").font(.caption).foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(24)
    } else {
      let needsYou = workspaces.filter { ($0.unread > 0) || ($0.remote != nil && $0.remote.connected == false) }
      if needsYou.count > 0 {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundColor("#E0AF68")
            Text("Needs you").font(.system(size: 11)).fontWeight(.semibold).foregroundColor("#E0AF68").textCase(.uppercase)
            Spacer()
            Text("\(needsYou.count)").font(.system(size: 10, design: .monospaced)).foregroundColor("#E0AF68")
          }
          ForEach(needsYou.sorted { $0.unread > $1.unread }) { w in
            HStack(spacing: 8) {
              dot(statusColor(w), 9)
              Text(w.title).font(.system(size: 12)).foregroundColor("#C0CAF5").lineLimit(1)
              Spacer()
              Text(statusLabel(w)).font(.system(size: 9, design: .monospaced)).foregroundColor(statusColor(w))
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { RoundedRectangle(cornerRadius: 9).foregroundColor("#16161E") }
            .onTapGesture { cmux("workspace.select", workspace_id: w.id) }
            .contextMenu {
              Button("Select") { cmux("workspace.select", workspace_id: w.id) }
              Button("Stop agent") { cmux("workspace.stop", workspace_id: w.id) }
            }
          }
        }
        .padding(10)
        .background {
          RoundedRectangle(cornerRadius: 12).foregroundColor("#15140F")
            .overlay { RoundedRectangle(cornerRadius: 12).stroke("#E0AF68", lineWidth: 1).opacity(0.35) }
        }
      }

      Text("All workspaces").font(.system(size: 11)).fontWeight(.semibold).foregroundColor(.secondary).textCase(.uppercase)

      let sorted = workspaces.sorted { $0.index < $1.index }
      Grid(horizontalSpacing: 10, verticalSpacing: 10) {
        ForEach(sorted.indices) { i in
          if i % 2 == 0 {
            GridRow {
              card(sorted[i])
              if i + 1 < sorted.count {
                card(sorted[i + 1])
              } else {
                Color("#0D0D14").opacity(0.0)
              }
            }
          }
        }
      }
    }

    Spacer()
  }
  .padding(12)
}
.scrollIndicators(.hidden)