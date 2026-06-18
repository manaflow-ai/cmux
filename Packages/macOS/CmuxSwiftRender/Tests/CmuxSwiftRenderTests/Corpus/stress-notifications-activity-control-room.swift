func ringColor(_ n: Int) -> String {
  return n >= 10 ? "#F7768E" : n >= 4 ? "#E0AF68" : n >= 1 ? "#7AA2F7" : "#565F89"
}

func ago(_ at: Double) -> String {
  let d = clock.epoch - at
  if d < 60 { return "now" }
  if d < 3600 { return "\(Int(d / 60))m" }
  if d < 86400 { return "\(Int(d / 3600))h" }
  return "\(Int(d / 86400))d"
}

func severityIcon(_ n: Int) -> String {
  return n >= 10 ? "exclamationmark.2" : n >= 4 ? "bell.badge.fill" : "bell.fill"
}

func chip(_ icon: String, _ label: String, _ tint: String) -> some View {
  HStack(spacing: 4) {
    Image(systemName: icon).font(.system(size: 9)).foregroundColor(tint)
    Text(label).font(.system(size: 10)).fontWeight(.semibold).foregroundColor(tint).lineLimit(1)
  }
  .padding(4)
  .background(tint == "#565F89" ? "#1A1B26" : "#1F2335")
  .cornerRadius(6)
  .overlay(Capsule().stroke(tint, lineWidth: 0.5).opacity(0.4))
}

let unreadWs = workspaces.filter { $0.unread > 0 }.sorted { $0.unread > $1.unread }
let peak = max(1, unreadWs.map { $0.unread }.reduce(0) { max($0, $1) })
let readyWs = workspaces.filter { $0.unread == 0 }
let hotCount = workspaces.filter { $0.unread >= 10 }.count
let accent = ringColor(unreadTotal)

ScrollView {
  LazyVStack(alignment: .leading, spacing: 12) {

    ForEach(unreadWs) { ws in
      let ring = ringColor(ws.unread)
      let share = Double(ws.unread) / Double(peak)
      VStack(alignment: .leading, spacing: 7) {

        HStack(spacing: 8) {
          ZStack {
            Circle().foregroundColor("#1A1B26").frame(width: 34, height: 34)
            Circle()
              .stroke(ring, lineWidth: 2)
              .frame(width: 34, height: 34)
              .opacity(0.5 + 0.5 * share)
            Text("\(min(ws.unread, 99))")
              .font(.system(size: 12))
              .fontWeight(.semibold)
              .foregroundColor(ring)
          }
          .overlay(alignment: .topTrailing) {
            Image(systemName: severityIcon(ws.unread))
              .font(.system(size: 8))
              .foregroundColor("#1A1B26")
              .padding(3)
              .background(ring)
              .clipShape(Circle())
              .offset(x: 4, y: -4)
          }
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
              if ws.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundColor("#E0AF68").rotationEffect(.degrees(40)) }
              Text(ws.title).font(.system(size: 13)).fontWeight(.semibold).foregroundColor(ws.selected ? "#C0CAF5" : "#A9B1D6").lineLimit(1)
              Spacer(minLength: 2)
              Text(ago(ws.latestAt)).font(.system(size: 10)).fontDesign(.monospaced).foregroundColor(.secondary)
            }
            HStack(spacing: 4) {
              chip("number", "\(ws.unread) unread", ring)
              if ws.dirty { chip("pencil.line", "dirty", "#E0AF68") }
              if ws.portCount > 0 { chip("network", "\(ws.portCount)", "#7AA2F7") }
            }
          }
        }

        Text(ws.latestMessage)
          .font(.system(size: 11))
          .foregroundColor(ws.selected ? "#C0CAF5" : .secondary)
          .lineLimit(2)
          .truncationMode(.tail)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(7)
          .background("#16161E")
          .cornerRadius(8)
          .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).foregroundColor(ring).frame(width: 3).padding(2)
          }

        HStack(spacing: 6) {
          Button { cmux("workspace.select", workspace_id: ws.id) } label: {
            HStack(spacing: 4) {
              Image(systemName: "arrow.right.circle.fill").font(.system(size: 10))
              Text("Open").font(.system(size: 11)).fontWeight(.semibold)
            }
            .padding(5)
            .frame(maxWidth: .infinity)
            .background(ring)
            .foregroundColor("#1A1B26")
            .cornerRadius(7)
          }
          Button { cmux("workspace.markRead", workspace_id: ws.id) } label: {
            Image(systemName: "checkmark.circle").font(.system(size: 12)).foregroundColor(.secondary)
              .padding(5)
              .background("#1F2335")
              .cornerRadius(7)
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
      .padding(9)
      .background("#1A1B26")
      .cornerRadius(12)
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(ring, lineWidth: ws.selected ? 1.5 : 1).opacity(ws.selected ? 0.9 : 0.35))
      .shadow(radius: ws.unread >= 10 ? 6 : 0, x: 0, y: 1, color: ring)
      .onTapGesture { cmux("workspace.select", workspace_id: ws.id) }
      .contextMenu {
        Button("Open") { cmux("workspace.select", workspace_id: ws.id) }
        Button("Mark read") { cmux("workspace.markRead", workspace_id: ws.id) }
        Button(ws.pinned ? "Unpin" : "Pin") { cmux("workspace.togglePin", workspace_id: ws.id) }
      }
    }

    if unreadWs.count == 0 {
      VStack(spacing: 8) {
        Image(systemName: "bell.slash.fill").font(.system(size: 28)).foregroundColor("#9ECE6A").symbolRenderingMode(.hierarchical)
        Text("Inbox zero").font(.system(size: 14)).fontWeight(.semibold).foregroundColor("#9ECE6A")
        Text("All \(workspaceCount) workspaces are caught up.").font(.system(size: 11)).foregroundColor(.secondary).multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
      .padding(20)
      .background("#16161E")
      .cornerRadius(12)
    }

    if readyWs.count > 0 {
      Divider().padding(2)
      HStack(spacing: 5) {
        Image(systemName: "checkmark.seal.fill").font(.system(size: 10)).foregroundColor("#9ECE6A")
        Text("Caught up").font(.system(size: 10)).fontWeight(.semibold).textCase(.uppercase).foregroundColor(.secondary)
        Spacer()
        Text("\(readyWs.count)").font(.system(size: 10)).fontDesign(.monospaced).foregroundColor(.secondary)
      }
      ScrollView(.horizontal) {
        HStack(spacing: 6) {
          ForEach(readyWs) { ws in
            HStack(spacing: 4) {
              Circle().foregroundColor(ws.selected ? "#7AA2F7" : "#565F89").frame(width: 6, height: 6)
              Text(ws.title).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            }
            .padding(5)
            .background("#16161E")
            .cornerRadius(8)
            .overlay(Capsule().stroke("#565F89", lineWidth: 0.5).opacity(0.4))
            .onTapGesture { cmux("workspace.select", workspace_id: ws.id) }
          }
        }
        .padding(1)
      }
      .scrollIndicators(.hidden)
    }
  }
  .padding(10)
}
.safeAreaInset(edge: .top) {
  VStack(spacing: 8) {
    HStack(spacing: 10) {
      Gauge(value: Double(unreadTotal), total: Double(max(unreadTotal, workspaceCount * 5))) {
        Image(systemName: "bell.fill")
      }
      .tint(accent)
      .scaleEffect(1.05)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 4) {
          Text("\(unreadTotal)").font(.system(size: 22)).fontWeight(.semibold).foregroundColor(accent)
          Text("unread").font(.system(size: 11)).foregroundColor(.secondary)
          Spacer()
        }
        Text(unreadTotal == 0 ? "all clear" : "\(unreadWs.count) of \(workspaceCount) need you").font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
      }
      ZStack {
        Circle().stroke("#1F2335", lineWidth: 3).frame(width: 30, height: 30)
        Text("\(clock.hour):\(clock.minute < 10 ? "0" : "")\(clock.minute)").font(.system(size: 8)).fontDesign(.monospaced).foregroundColor(.secondary)
      }
    }
    HStack(spacing: 5) {
      chip("flame.fill", "\(hotCount) hot", hotCount > 0 ? "#F7768E" : "#565F89")
      chip("tray.full.fill", "\(unreadWs.count) active", unreadWs.count > 0 ? "#7AA2F7" : "#565F89")
      chip("checkmark.seal.fill", "\(readyWs.count) clear", "#9ECE6A")
      Spacer()
    }
    ProgressView(value: Double(workspaceCount - unreadWs.count), total: Double(max(1, workspaceCount)))
      .tint("#9ECE6A")
  }
  .padding(10)
  .background {
    ZStack {
      Color("#16161E")
      Rectangle().foregroundColor(accent).opacity(0.06)
    }
  }
  .overlay(alignment: .bottom) {
    Rectangle().foregroundColor(accent).frame(height: 1).opacity(0.4)
  }
}