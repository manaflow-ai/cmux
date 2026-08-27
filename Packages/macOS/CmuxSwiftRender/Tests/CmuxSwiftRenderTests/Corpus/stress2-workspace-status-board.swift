// Workspace status board: a per-workspace status is derived (unread/dirty/progress/remote)
// in a value func, then a single switch maps that status to BOTH a color and an SF symbol.
// Rows render in a Grid as gradient-filled status pills wrapped in stroked rings.

// ── Derive one canonical status string per workspace from its live signals ──
func statusOf(_ w) -> String {
  if let remote = w.remote {
    if remote.connected == false { return "offline" }
  }
  if let prog = w.progress {
    if prog.value < 1.0 { return "running" }
  }
  if w.unread > 0 { return "unread" }
  if let dirty = w.dirty {
    if dirty { return "dirty" }
  }
  return "clean"
}

// ── switch in a value func returning a hex color for the status ──
func statusColor(_ s) -> String {
  switch s {
  case "offline": return "#8E8E93"
  case "running": return "#0A84FF"
  case "unread":  return "#FF9F0A"
  case "dirty":   return "#FF453A"
  case "clean":   return "#30D158"
  default:        return "#5E5CE6"
  }
}

// ── switch returning the matching SF symbol for the status ──
func statusSymbol(_ s) -> String {
  switch s {
  case "offline": return "bolt.horizontal.circle.fill"
  case "running": return "arrow.triangle.2.circlepath"
  case "unread":  return "bell.badge.fill"
  case "dirty":   return "pencil.circle.fill"
  case "clean":   return "checkmark.circle.fill"
  default:        return "circle.dashed"
  }
}

func statusLabel(_ s) -> String {
  switch s {
  case "offline": return "OFFLINE"
  case "running": return "RUNNING"
  case "unread":  return "UNREAD"
  case "dirty":   return "DIRTY"
  case "clean":   return "CLEAN"
  default:        return s
  }
}

// ── A gradient-filled status pill with a glyph, used in the header tallies ──
func statusPill(_ s, _ count: Int) -> some View {
  let c = statusColor(s)
  return HStack {
    Image(systemName: statusSymbol(s))
      .font(.system(size: 10))
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle("#FFFFFF")
    Text("\(count)")
      .font(.system(size: 11, design: .monospaced))
      .bold()
      .monospacedDigit()
      .foregroundStyle("#FFFFFF")
  }
  .padding(.horizontal, 8)
  .padding(.vertical, 4)
  .background {
    Capsule()
      .fill(LinearGradient(colors: [c, "#0D1117"], startPoint: .top, endPoint: .bottom))
      .overlay(alignment: .center) {
        Capsule().stroke(c, lineWidth: 1)
      }
      .opacity(count > 0 ? 1.0 : 0.35)
  }
  .help("\(statusLabel(s)): \(count)")
}

// ── One workspace row: a stroked ring around a status glyph + gradient pill + meta ──
func boardRow(_ w) -> some View {
  let s = statusOf(w)
  let c = statusColor(s)
  let prog = w.progress
  return GridRow {
    // Stroked ring with the status glyph; a trimmed inner arc shows progress when running.
    ZStack {
      Circle()
        .stroke("#23272E", lineWidth: 3)
        .frame(width: 34, height: 34)
      Circle()
        .trim(from: 0.0, to: s == "running" ? (prog == nil ? 0.25 : min(max(prog.value, 0.05), 1.0)) : 1.0)
        .stroke(c, lineWidth: 3)
        .frame(width: 34, height: 34)
        .rotationEffect(.degrees(-90))
      Image(systemName: statusSymbol(s))
        .font(.system(size: 13))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(c)
    }
    .frame(width: 38, height: 38)

    // Title + branch/dir meta.
    VStack(alignment: .leading) {
      HStack {
        Text(w.title)
          .font(.system(size: 12))
          .fontWeight(w.selected ? .bold : .regular)
          .lineLimit(1)
          .truncationMode(.tail)
          .foregroundStyle(w.selected ? "#FFFFFF" : "#C9D1D9")
        if w.pinned {
          Image(systemName: "pin.fill")
            .font(.system(size: 8))
            .foregroundStyle("#FF9F0A")
        }
      }
      HStack {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 8))
          .foregroundStyle(.tertiary)
        Text(w.branch == nil ? "no branch" : w.branch)
          .font(.system(size: 9, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)

    // Gradient status pill on the trailing edge, with an unread badge overlay.
    HStack {
      Text(statusLabel(s))
        .font(.system(size: 8, design: .monospaced))
        .bold()
        .foregroundStyle("#FFFFFF")
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background {
      Capsule()
        .fill(LinearGradient(colors: [c, "#0D1117"], startPoint: .leading, endPoint: .trailing))
    }
    .overlay(alignment: .topTrailing) {
      if w.unread > 0 {
        Text("\(min(w.unread, 99))")
          .font(.system(size: 7, design: .monospaced))
          .bold()
          .monospacedDigit()
          .foregroundStyle("#FFFFFF")
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background { Capsule().fill("#FF453A") }
          .offset(x: 6, y: -6)
      }
    }
  }
}

// ── Compose the board ──
ScrollView {
  VStack(alignment: .leading) {

    // Header: angular-gradient ring badge + live tally of statuses across all workspaces.
    let statuses = workspaces.map { statusOf($0) }
    HStack {
      ZStack {
        Circle()
          .fill(AngularGradient(colors: ["#30D158", "#0A84FF", "#FF9F0A", "#FF453A", "#30D158"], startPoint: .top, endPoint: .bottom))
          .frame(width: 40, height: 40)
        Circle()
          .fill("#0D1117")
          .frame(width: 30, height: 30)
        Image(systemName: "square.grid.2x2.fill")
          .font(.system(size: 13))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle("#FFFFFF")
      }
      VStack(alignment: .leading) {
        Text("STATUS BOARD")
          .font(.system(size: 13))
          .bold()
          .foregroundStyle("#FFFFFF")
        Text("\(workspaceCount) workspaces · \(unreadTotal) unread · \(clock.time)")
          .font(.system(size: 9, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.bottom, 4)

    // Tally strip: one gradient pill per status kind, count derived via filter.
    ScrollView(.horizontal) {
      HStack {
        ForEach(["clean", "dirty", "unread", "running", "offline"]) { kind in
          statusPill(kind, statuses.filter { $0 == kind }.count)
        }
      }
      .padding(.vertical, 2)
    }
    .scrollIndicators(.hidden)

    Divider().padding(.vertical, 4)

    // The board itself: a Grid of GridRows, one per workspace, with select-on-tap.
    Grid(alignment: .leading) {
      ForEach(workspaces) { w in
        boardRow(w)
          .onTapGesture { cmux("workspace.select", value: w.id) }
      }
    }

    if workspaceCount == 0 {
      Text("No workspaces")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 12)
    }

    Divider().padding(.vertical, 4)

    // Footer legend: status → symbol + label, proving the switch mapping end-to-end.
    Text("LEGEND")
      .font(.caption)
      .fontWeight(.semibold)
      .foregroundStyle(.tertiary)
      .textCase(.uppercase)
    LazyVGrid(columns: 2) {
      ForEach(["clean", "dirty", "unread", "running", "offline"]) { kind in
        HStack {
          Image(systemName: statusSymbol(kind))
            .font(.system(size: 10))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(statusColor(kind))
          Text(statusLabel(kind))
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
  .padding(12)
}
.scrollIndicators(.hidden)
.background("#010409")