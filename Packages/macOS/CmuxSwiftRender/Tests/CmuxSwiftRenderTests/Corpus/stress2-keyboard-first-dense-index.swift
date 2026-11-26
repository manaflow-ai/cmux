func statusGlyph(_ w) -> String {
  if w.remote != nil && w.remote.connected == false { return "R" }
  if w.unread > 0 { return "U" }
  if w.progress != nil && w.progress.value < 1.0 { return "~" }
  if w.dirty == true { return "M" }
  if w.pr != nil && w.pr.status == "open" { return "P" }
  return "." }

func glyphColor(_ g) -> String {
  switch g {
  case "R": return "#F7768E"
  case "U": return "#E0AF68"
  case "~": return "#7AA2F7"
  case "M": return "#BB9AF7"
  case "P": return "#73DACA"
  default: return "#565F89" } }

func glyphLabel(_ g) -> String {
  switch g {
  case "R": return "remote down"
  case "U": return "unread"
  case "~": return "running"
  case "M": return "modified"
  case "P": return "pr open"
  default: return "clean" } }

func indexKey(_ i) -> String {
  let keys = "123456789abcdefghijklmnopqrstuvwxyz"
  return i < keys.count ? String(keys[i]) : "·" }

func metaLine(_ w) -> String {
  let g = statusGlyph(w)
  if g == "U" { return "\(w.unread) unread" }
  if g == "~" && w.progress != nil { return w.progress.label }
  if g == "M" && w.branch != nil { return w.branch }
  if g == "P" && w.pr != nil { return "PR #\(w.pr.number)" }
  if w.branch != nil { return w.branch }
  if w.portCount > 0 { return "\(w.portCount) port" }
  return w.directory }

func glyphCell(_ g, _ accent, _ on) -> some View {
  Text(g)
    .font(.system(size: 12, design: .monospaced))
    .bold()
    .foregroundColor(on ? "#0D0D14" : accent)
    .frame(width: 18, height: 18)
    .background {
      RoundedRectangle(cornerRadius: 5)
        .fill(on ? accent : "#16161E")
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(accent, lineWidth: 1).opacity(on ? 0.0 : 0.45) } } }

func row(_ w, _ i) -> some View {
  let g = statusGlyph(w)
  let accent = w.color != nil ? w.color : glyphColor(g)
  let sel = w.selected
  let key = indexKey(i)
  HStack(spacing: 8) {
    Text(key)
      .font(.system(size: 11, design: .monospaced))
      .bold()
      .foregroundColor(sel ? accent : .tertiary)
      .frame(width: 13, alignment: .trailing)
      .monospacedDigit()
    glyphCell(g, accent, g != ".")
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 5) {
        if w.pinned == true {
          Image(systemName: "pin.fill").font(.system(size: 8)).foregroundColor(accent)
        }
        Text(w.title)
          .font(.system(size: 12))
          .fontWeight(sel ? .semibold : .regular)
          .foregroundColor(sel ? "#C0CAF5" : "#A9B1D6")
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Text(metaLine(w))
        .font(.system(size: 9, design: .monospaced))
        .foregroundColor(.tertiary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    Spacer(minLength: 4)
    if w.unread > 0 {
      Text("\(min(w.unread, 99))")
        .font(.system(size: 9, design: .monospaced))
        .bold()
        .foregroundColor("#0D0D14")
        .padding(3)
        .frame(minWidth: 16)
        .background { Capsule().fill("#E0AF68") }
    } else if w.tabCount > 1 {
      Text("\(w.tabCount)t")
        .font(.system(size: 9, design: .monospaced))
        .foregroundColor(.tertiary)
    }
  }
  .padding(6)
  .frame(maxWidth: .infinity, alignment: .leading)
  .background {
    RoundedRectangle(cornerRadius: 8)
      .fill(sel ? "#171826" : "#0F0F17")
      .opacity(sel ? 1.0 : 0.0)
  }
  .overlay(alignment: .leading) {
    Capsule()
      .fill(accent)
      .frame(width: 2.5)
      .padding(.vertical, 3)
      .opacity(sel ? 1.0 : 0.0)
  }
  .opacity(g == "R" ? 0.6 : 1.0)
  .onTapGesture { cmux("workspace.select", workspace_id: w.id) }
  .keyboardShortcut(.return)
  .contextMenu {
    Button("Select") { cmux("workspace.select", workspace_id: w.id) }
    Button("Stop agent") { cmux("workspace.stop", workspace_id: w.id) }
    Button(w.pinned == true ? "Unpin" : "Pin") { cmux("workspace.pin", workspace_id: w.id) }
    if w.pr != nil {
      Button("Open PR") { cmux("workspace.openPR", workspace_id: w.id) }
    }
  }
  .help("\(key) → \(w.title) · \(glyphLabel(g))") }

func legendDot(_ g) -> some View {
  HStack(spacing: 3) {
    Text(g).font(.system(size: 9, design: .monospaced)).bold().foregroundColor(glyphColor(g))
    Text(glyphLabel(g)).font(.system(size: 8)).foregroundColor(.tertiary)
  } }

ScrollView {
  let sorted = workspaces.sorted { $0.index < $1.index }
  let pinned = sorted.filter { $0.pinned == true }
  let rest = sorted.filter { $0.pinned != true }
  let attn = workspaces.filter { (statusGlyph($0) == "U") || (statusGlyph($0) == "R") }.count

  VStack(alignment: .leading, spacing: 10) {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "command").font(.system(size: 12)).foregroundColor("#7AA2F7")
      Text("INDEX")
        .font(.system(size: 12, design: .monospaced))
        .bold()
        .foregroundColor("#C0CAF5")
        .textCase(.uppercase)
      Text("\(workspaceCount)")
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor(.tertiary)
      Spacer()
      Text("\(clock.time)")
        .font(.system(size: 10, design: .monospaced))
        .monospacedDigit()
        .foregroundColor(.secondary)
    }

    HStack(spacing: 8) {
      legendDot("~")
      legendDot("M")
      legendDot("U")
      legendDot("P")
      Spacer()
      if attn > 0 {
        Text("\(attn)!")
          .font(.system(size: 9, design: .monospaced))
          .bold()
          .foregroundColor("#0D0D14")
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background { Capsule().fill("#F7768E") }
      }
    }
    .padding(.horizontal, 2)

    Rectangle().fill("#272A3D").frame(height: 1).opacity(0.6)

    if workspaceCount == 0 {
      VStack(spacing: 8) {
        Image(systemName: "list.number").font(.system(size: 26)).foregroundColor(.tertiary).symbolRenderingMode(.hierarchical)
        Text("No workspaces").font(.caption).foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 28)
    } else {
      if pinned.count > 0 {
        Text("PINNED")
          .font(.system(size: 9, design: .monospaced))
          .foregroundColor(.tertiary)
          .textCase(.uppercase)
          .padding(.leading, 2)
        LazyVStack(spacing: 2) {
          ForEach(Array(pinned.enumerated()), id: \.offset) { i, w in
            row(w, w.index)
          }
        }
      }

      Text("WORKSPACES")
        .font(.system(size: 9, design: .monospaced))
        .foregroundColor(.tertiary)
        .textCase(.uppercase)
        .padding(.leading, 2)
        .padding(.top, pinned.count > 0 ? 2 : 0)
      LazyVStack(spacing: 2) {
        ForEach(Array(rest.enumerated()), id: \.offset) { i, w in
          row(w, w.index)
        }
      }

      HStack(spacing: 4) {
        Image(systemName: "return").font(.system(size: 8)).foregroundColor(.tertiary)
        Text("press the key to switch")
          .font(.system(size: 8, design: .monospaced))
          .foregroundColor(.tertiary)
        Spacer()
        if unreadTotal > 0 {
          Text("\(unreadTotal) unread total")
            .font(.system(size: 8, design: .monospaced))
            .foregroundColor("#E0AF68")
        }
      }
      .padding(.horizontal, 2)
      .padding(.top, 4)
    }
  }
  .padding(10)
}
.scrollIndicators(.hidden)