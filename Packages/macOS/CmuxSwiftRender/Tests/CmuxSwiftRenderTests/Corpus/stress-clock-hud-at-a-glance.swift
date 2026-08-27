func pad(_ n: Int) -> String { return n < 10 ? "0\(n)" : "\(n)" }
func ampm(_ h: Int) -> String { return h < 12 ? "AM" : "PM" }
func hour12(_ h: Int) -> Int { let v = h % 12; return v == 0 ? 12 : v }
func greeting(_ h: Int) -> String {
  return h < 5 ? "burning the midnight oil" : h < 12 ? "good morning" : h < 17 ? "good afternoon" : h < 22 ? "good evening" : "winding down"
}
func dayColor(_ wd: String) -> String {
  return wd == "Saturday" || wd == "Sunday" ? "#E0AF68" : "#7AA2F7"
}

func ringSweep(_ progress: Double, _ tint: String) -> some View {
  return ZStack {
    Circle().stroke("#1F2335", lineWidth: 8)
    Circle()
      .trim(from: 0.0, to: progress)
      .stroke(tint, lineWidth: 8)
      .rotationEffect(.degrees(-90))
  }
}

func statTile(_ label: String, _ value: String, _ icon: String, _ tint: String) -> some View {
  return VStack(alignment: .leading, spacing: 4) {
    HStack(spacing: 4) {
      Image(systemName: icon).font(.caption2).foregroundColor(tint).symbolRenderingMode(.hierarchical)
      Text(label).font(.system(size: 9, design: .default)).textCase(.uppercase).foregroundColor(.secondary).lineLimit(1)
    }
    Text(value).font(.system(size: 20, design: .monospaced)).bold().foregroundColor(tint)
  }
  .padding(10)
  .frame(maxWidth: .infinity, alignment: .leading)
  .background("#16161E")
  .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint, lineWidth: 1).opacity(0.35))
  .cornerRadius(12)
}

VStack(alignment: .leading, spacing: 14) {
  let h = clock.hour
  let m = clock.minute
  let s = clock.second
  let dayTint = dayColor(clock.weekday)
  let secFrac = Double(s) / 60.0
  let minFrac = (Double(m) + secFrac) / 60.0
  let dayFrac = (Double(h) * 3600.0 + Double(m) * 60.0 + Double(s)) / 86400.0

  let pinned = workspaces.filter { $0.pinned }
  let dirtyCount = workspaces.filter { $0.dirty }.count
  let portsLive = workspaces.flatMap { $0.ports }.count
  let busy = workspaces.filter { $0.unread > 0 }.sorted { $0.unread > $1.unread }
  let openPRs = workspaces.filter { $0.pr.status == "open" }.count

  // ---- HERO: big clock with concentric rings ----
  ZStack {
    ZStack {
      ringSweep(dayFrac, "#565F89").scaleEffect(1.0)
      ringSweep(minFrac, "#7AA2F7").padding(12)
      ringSweep(secFrac, "#9ECE6A").padding(24)
    }
    .frame(width: 150, height: 150)

    VStack(spacing: 2) {
      Text("\(hour12(h)):\(pad(m))")
        .font(.system(size: 38, design: .monospaced)).bold().foregroundColor("#C0CAF5")
      HStack(spacing: 4) {
        Text(":\(pad(s))").font(.system(size: 14, design: .monospaced)).foregroundColor("#9ECE6A")
        Text(ampm(h)).font(.system(size: 11, design: .monospaced)).fontWeight(.semibold).foregroundColor(.secondary)
      }
    }
  }
  .frame(maxWidth: .infinity, alignment: .center)
  .padding(.top, 6)

  // ---- weekday + greeting ----
  VStack(alignment: .leading, spacing: 2) {
    Text(clock.weekday).font(.title2).bold().foregroundColor(dayTint)
    Text(greeting(h)).font(.caption).italic().foregroundColor(.secondary)
  }
  .frame(maxWidth: .infinity, alignment: .leading)
  .padding(.horizontal, 2)

  // ---- ViewThatFits adaptive summary line ----
  ViewThatFits {
    HStack(spacing: 6) {
      Text("\(workspaceCount) workspaces").font(.caption).foregroundColor("#7AA2F7")
      Text("·").foregroundColor(.tertiary)
      Text("\(unreadTotal) unread").font(.caption).foregroundColor("#F7768E")
      Text("·").foregroundColor(.tertiary)
      Text("\(dirtyCount) dirty").font(.caption).foregroundColor("#E0AF68")
      Text("·").foregroundColor(.tertiary)
      Text("\(portsLive) ports").font(.caption).foregroundColor("#9ECE6A")
    }
    HStack(spacing: 6) {
      Text("\(workspaceCount) ws").font(.caption).foregroundColor("#7AA2F7")
      Text("·").foregroundColor(.tertiary)
      Text("\(unreadTotal) unread").font(.caption).foregroundColor("#F7768E")
      Text("·").foregroundColor(.tertiary)
      Text("\(dirtyCount) dirty").font(.caption).foregroundColor("#E0AF68")
    }
    Text("\(workspaceCount) ws · \(unreadTotal) unread").font(.caption).foregroundColor(.secondary).lineLimit(1)
  }
  .padding(.horizontal, 2)

  Divider()

  // ---- Gauges grid: workspace count + unread total ----
  Grid {
    GridRow {
      VStack(spacing: 6) {
        Gauge(value: Double(workspaceCount), total: Double(max(workspaceCount, 12))) {
          Text("WS").font(.system(size: 9)).foregroundColor(.secondary)
        }
        .tint("#7AA2F7")
        Text("\(workspaceCount)").font(.system(size: 16, design: .monospaced)).bold().foregroundColor("#7AA2F7")
        Text("workspaces").font(.system(size: 9)).textCase(.uppercase).foregroundColor(.secondary)
      }
      .padding(10).frame(maxWidth: .infinity).background("#16161E").cornerRadius(12)

      VStack(spacing: 6) {
        Gauge(value: Double(min(unreadTotal, 50)), total: 50.0) {
          Text("RX").font(.system(size: 9)).foregroundColor(.secondary)
        }
        .tint(unreadTotal > 0 ? "#F7768E" : "#565F89")
        Text("\(unreadTotal)").font(.system(size: 16, design: .monospaced)).bold().foregroundColor(unreadTotal > 0 ? "#F7768E" : .secondary)
        Text("unread").font(.system(size: 9)).textCase(.uppercase).foregroundColor(.secondary)
      }
      .padding(10).frame(maxWidth: .infinity).background("#16161E").cornerRadius(12)
    }
  }
  .padding(.horizontal, 2)

  // ---- stat tiles row ----
  HStack(spacing: 10) {
    statTile("dirty", "\(dirtyCount)", "exclamationmark.triangle.fill", "#E0AF68")
    statTile("pinned", "\(pinned.count)", "pin.fill", "#BB9AF7")
    statTile("PRs", "\(openPRs)", "arrow.triangle.pull", "#9ECE6A")
  }
  .padding(.horizontal, 2)

  Divider()

  // ---- "needs attention" list, ranked by unread ----
  Section("Needs attention") {
    if busy.count == 0 {
      HStack {
        Image(systemName: "checkmark.seal.fill").foregroundColor("#9ECE6A").imageScale(.large)
        Text("inbox zero across all workspaces").font(.caption).foregroundColor(.secondary)
      }
      .padding(10).frame(maxWidth: .infinity, alignment: .leading).background("#16161E").cornerRadius(10)
    } else {
      ForEach(busy.prefix(6)) { w in
        let urgent = w.unread > 5
        let tint = urgent ? "#F7768E" : "#E0AF68"
        HStack(spacing: 8) {
          ZStack {
            Circle().fill(tint).frame(width: 26, height: 26).opacity(0.18)
            Text("\(w.unread)").font(.system(size: 11, design: .monospaced)).bold().foregroundColor(tint)
          }
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
              if w.selected { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundColor("#7AA2F7") }
              Text(w.title).font(.callout).fontWeight(.semibold).lineLimit(1).foregroundColor(w.selected ? "#C0CAF5" : .primary)
            }
            HStack(spacing: 6) {
              if w.dirty { Text("● dirty").font(.system(size: 9)).foregroundColor("#E0AF68") }
              Text("\(w.tabCount) tabs").font(.system(size: 9)).foregroundColor(.secondary)
              if w.portCount > 0 { Text(":\(w.ports.first)").font(.system(size: 9, design: .monospaced)).foregroundColor("#9ECE6A") }
            }
          }
          Spacer()
          Button { cmux("workspace.markRead", workspace_id: w.id) } label: {
            Image(systemName: "envelope.open").font(.caption).foregroundColor(.secondary)
          }
          .help("Mark read")
        }
        .padding(8)
        .background(w.selected ? "#1F2335" : "#16161E")
        .overlay(alignment: .topTrailing) {
          urgent ? AnyView(Circle().fill("#F7768E").frame(width: 6, height: 6).offset(x: -6, y: 6)) : AnyView(EmptyView())
        }
        .cornerRadius(10)
        .onTapGesture { cmux("workspace.select", workspace_id: w.id) }
        .contextMenu {
          Button("Open") { cmux("workspace.select", workspace_id: w.id) }
          Button("Mark read") { cmux("workspace.markRead", workspace_id: w.id) }
        }
      }
    }
  }
  .padding(.horizontal, 2)

  // ---- selected workspace footer ----
  Divider()
  HStack(spacing: 8) {
    Image(systemName: "scope").font(.caption).foregroundColor("#7AA2F7").symbolRenderingMode(.hierarchical)
    VStack(alignment: .leading, spacing: 1) {
      Text("focused").font(.system(size: 8)).textCase(.uppercase).foregroundColor(.tertiary)
      Text(selectedTitle).font(.caption).fontWeight(.semibold).lineLimit(1).foregroundColor("#C0CAF5")
    }
    Spacer()
    Text("\(pad(h)):\(pad(m)):\(pad(s))").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
  }
  .padding(10)
  .frame(maxWidth: .infinity, alignment: .leading)
  .background("#16161E")
  .cornerRadius(10)
  .padding(.horizontal, 2)

  Spacer()
}
.padding(12)