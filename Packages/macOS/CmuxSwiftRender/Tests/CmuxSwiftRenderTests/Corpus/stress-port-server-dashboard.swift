// ── Port & Server Dashboard ──────────────────────────────────────────
// Groups workspaces by whether they expose ports, shows ports as Capsule
// chips in a horizontal ScrollView, and surfaces progress with ProgressView.

func portColor(_ p: Int) -> String {
    if p == 3000 || p == 5173 || p == 8080 { return "#0A84FF" }
    if p == 443 || p == 80 || p == 8443 { return "#34C759" }
    if p == 5432 || p == 6379 || p == 27017 || p == 3306 { return "#FF9F0A" }
    if p >= 9000 { return "#BF5AF2" }
    return "#64D2FF"
}

func portTag(_ p: Int) -> String {
    if p == 3000 || p == 5173 { return "web" }
    if p == 8080 || p == 8000 { return "api" }
    if p == 443 || p == 80 || p == 8443 { return "https" }
    if p == 5432 { return "pg" }
    if p == 6379 { return "redis" }
    if p == 27017 { return "mongo" }
    if p == 3306 { return "mysql" }
    return "tcp"
}

func remoteIcon(_ ws) -> String {
    if ws.remote.connected { return "antenna.radiowaves.left.and.right" }
    if ws.remote.state == "connecting" { return "antenna.radiowaves.left.and.right.slash" }
    return "bolt.horizontal.circle"
}

// A single port chip: colored Capsule with the port number, a derived
// service tag overlaid as a tiny corner badge, tappable to focus the workspace.
func portChip(_ p: Int, _ wsId) -> some View {
    Text("\(p)")
        .font(.system(size: 11, design: .monospaced))
        .fontWeight(.semibold)
        .foregroundColor("#FFFFFF")
        .padding(6)
        .frame(minWidth: 44)
        .background {
            Capsule()
                .foregroundColor(portColor(p))
                .opacity(0.92)
                .overlay(alignment: .bottomTrailing) {
                    Capsule()
                        .foregroundColor("#000000")
                        .opacity(0.28)
                        .frame(width: 30, height: 9)
                        .overlay {
                            Text(portTag(p))
                                .font(.system(size: 6))
                                .textCase(.uppercase)
                                .foregroundColor("#FFFFFF")
                                .opacity(0.85)
                        }
                        .offset(x: -3, y: -3)
                }
        }
        .clipShape(Capsule())
        .shadow(radius: 3, x: 0, y: 1, color: portColor(p))
        .help("Port \(p) · \(portTag(p))")
        .onTapGesture { cmux("workspace.select", workspace_id: wsId) }
}

// The horizontal scroll strip of port chips for one workspace.
func portStrip(_ ws) -> some View {
    ScrollView(.horizontal) {
        HStack(spacing: 6) {
            ForEach(ws.ports.sorted { $0 < $1 }) { p in
                portChip(p, ws.id)
            }
            Image(systemName: "plus.circle.dashed")
                .imageScale(.large)
                .foregroundColor(.tertiary)
                .help("No more open ports")
        }
        .padding(2)
    }
    .scrollIndicators(.hidden)
}

// One workspace row. Header (status dot + title + branch + port count badge),
// optional ProgressView, the port strip, and a footer meta line. Whole row is
// wrapped in a rounded card whose tint follows selection.
func wsRow(_ ws) -> some View {
    let accent = ws.selected ? "#0A84FF" : "#3A3A3C"
    return VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .foregroundColor(ws.portCount > 0 ? "#34C759" : "#48484A")
                    .frame(width: 9, height: 9)
                if ws.portCount > 0 {
                    Circle()
                        .foregroundColor("#34C759")
                        .frame(width: 9, height: 9)
                        .opacity(0.35)
                        .scaleEffect(2.1)
                        .blur(radius: 2)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(ws.title)
                        .fontWeight(.semibold)
                        .foregroundColor(ws.selected ? "#FFFFFF" : "#E5E5EA")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if ws.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundColor("#FF9F0A")
                            .rotationEffect(.degrees(40))
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8))
                        .foregroundColor(.tertiary)
                    Text(ws.branch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(ws.dirty ? "#FF9F0A" : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if ws.dirty {
                        Circle().foregroundColor("#FF9F0A").frame(width: 4, height: 4)
                    }
                }
            }
            Spacer()
            Menu("⋯") {
                Button(action: { cmux("workspace.select", workspace_id: ws.id) }) {
                    Label("Focus", systemName: "scope")
                }
                Button(action: { cmux("workspace.select", workspace_id: ws.id) }) {
                    Label("\(ws.tabCount) tabs", systemName: "rectangle.stack")
                }
            }
            .foregroundColor(.secondary)
            Text("\(ws.portCount)")
                .font(.system(size: 11, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundColor(ws.portCount > 0 ? "#34C759" : .tertiary)
                .padding(4)
                .frame(minWidth: 26)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .foregroundColor(ws.portCount > 0 ? "#34C759" : "#48484A")
                        .opacity(0.18)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .border(.gray, width: 0)
                }
                .accessibilityLabel("\(ws.portCount) open ports")
        }

        // Progress, only when the workspace reports it.
        if ws.progress.value > 0 {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 9))
                        .foregroundColor("#BF5AF2")
                        .symbolRenderingMode(.hierarchical)
                    Text(ws.progress.label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text("\((ws.progress.value).formatted(.percent))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor("#BF5AF2")
                }
                ProgressView(value: ws.progress.value, total: 1.0)
                    .tint("#BF5AF2")
            }
            .padding(6)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .foregroundColor("#BF5AF2")
                    .opacity(0.08)
            }
        }

        // Ports as horizontal Capsule chips, or an empty hint.
        if ws.portCount > 0 {
            portStrip(ws)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.tertiary)
                Text("no listeners")
                    .font(.caption)
                    .italic()
                    .foregroundColor(.tertiary)
            }
            .padding(2)
        }

        // Footer meta: unread, tab count, remote status.
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                Image(systemName: remoteIcon(ws))
                    .font(.system(size: 9))
                    .foregroundColor(ws.remote.connected ? "#34C759" : .tertiary)
                Text(ws.remote.connected ? ws.remote.target : "local")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.tertiary)
                    .lineLimit(1)
            }
            HStack(spacing: 3) {
                Image(systemName: "rectangle.stack").font(.system(size: 9)).foregroundColor(.tertiary)
                Text("\(ws.tabCount)").font(.system(size: 9, design: .monospaced)).foregroundColor(.tertiary)
            }
            Spacer()
            if ws.unread > 0 {
                Text("\(ws.unread)")
                    .font(.system(size: 9))
                    .fontWeight(.semibold)
                    .foregroundColor("#FFFFFF")
                    .padding(3)
                    .frame(minWidth: 16)
                    .background { Capsule().foregroundColor("#FF453A") }
            }
        }
        .padding(1)
    }
    .padding(10)
    .background {
        RoundedRectangle(cornerRadius: 12)
            .foregroundColor(ws.selected ? "#0A84FF" : "#1C1C1E")
            .opacity(ws.selected ? 0.16 : 0.55)
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .foregroundColor("#000000")
                    .opacity(0.0)
                    .border(.gray, width: ws.selected ? 0 : 0)
            }
    }
    .overlay(alignment: .leading) {
        RoundedRectangle(cornerRadius: 2)
            .foregroundColor(accent)
            .frame(width: 3)
            .opacity(ws.selected ? 1.0 : 0.4)
            .padding(2)
    }
    .contextMenu {
        Button(action: { cmux("workspace.select", workspace_id: ws.id) }) {
            Label("Focus workspace", systemName: "scope")
        }
    }
}

// ── Derived aggregates over the live workspace set ───────────────────
let serving = workspaces.filter { $0.portCount > 0 }
let idle = workspaces.filter { $0.portCount == 0 }
let allPorts = workspaces.flatMap { $0.ports }
let totalPorts = allPorts.count
let buildingCount = workspaces.filter { $0.progress.value > 0 }.count
let avgBuild = buildingCount > 0
    ? workspaces.filter { $0.progress.value > 0 }.map { $0.progress.value }.reduce(0.0) { $0 + $1 } / Double(buildingCount)
    : 0.0

// ── Root ─────────────────────────────────────────────────────────────
List {
    // Summary header pinned at the top of the list.
    Section {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .imageScale(.large)
                    .foregroundColor("#0A84FF")
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Servers")
                        .font(.title)
                        .bold()
                        .foregroundColor("#FFFFFF")
                    Text("\(serving.count) serving · \(idle.count) idle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(totalPorts)")
                        .font(.system(size: 26, design: .monospaced))
                        .bold()
                        .foregroundColor("#34C759")
                    Text("PORTS")
                        .font(.system(size: 8))
                        .textCase(.uppercase)
                        .foregroundColor(.tertiary)
                }
            }

            // Stat tiles via Grid.
            Grid {
                GridRow {
                    statTile("rectangle.connected.to.line.below", "\(workspaceCount)", "spaces", "#64D2FF")
                    statTile("envelope.badge", "\(unreadTotal)", "unread", "#FF453A")
                    statTile("clock", "\(clock.time)", "now", "#FF9F0A")
                }
            }

            // A live build gauge if anything is compiling.
            if buildingCount > 0 {
                HStack(spacing: 8) {
                    Gauge(value: avgBuild) {
                        Image(systemName: "hammer.fill").foregroundColor("#BF5AF2")
                    }
                    .tint("#BF5AF2")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(buildingCount) building")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor("#FFFFFF")
                        Text("avg \((avgBuild).formatted(.percent))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    ProgressView()
                }
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .foregroundColor("#BF5AF2")
                        .opacity(0.1)
                }
            }
        }
        .padding(2)
    }

    // Serving group: workspaces with at least one open port.
    Section("Serving · \(serving.count)") {
        if serving.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "powersleep").foregroundColor(.tertiary)
                Text("Nothing listening")
                    .font(.caption)
                    .foregroundColor(.tertiary)
            }
            .padding(8)
        } else {
            ForEach(serving.sorted { $0.portCount > $1.portCount }) { ws in
                wsRow(ws)
            }
        }
    }

    // Idle group: no ports. Reorderable so the user can stage them.
    Section("Idle · \(idle.count)") {
        Reorderable(idle, move: "workspace.reorder") { ws in
            wsRow(ws)
        }
    }

    // Port legend footer.
    Section("Legend") {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach([3000, 8080, 443, 5432, 6379, 9000].indices) { i in
                    let demo = [3000, 8080, 443, 5432, 6379, 9000]
                    let p = demo[i]
                    HStack(spacing: 4) {
                        Capsule().foregroundColor(portColor(p)).frame(width: 14, height: 9)
                        Text(portTag(p))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                    }
                }
            }
            .padding(4)
        }
        .scrollIndicators(.hidden)
    }
}

// A compact stat tile used in the summary grid.
func statTile(_ icon: String, _ value: String, _ label: String, _ color: String) -> some View {
    VStack(spacing: 2) {
        Image(systemName: icon)
            .font(.system(size: 13))
            .foregroundColor(color)
            .symbolRenderingMode(.hierarchical)
        Text(value)
            .font(.system(size: 14, design: .monospaced))
            .fontWeight(.semibold)
            .foregroundColor("#FFFFFF")
            .lineLimit(1)
        Text(label)
            .font(.system(size: 8))
            .textCase(.uppercase)
            .foregroundColor(.tertiary)
    }
    .frame(maxWidth: .infinity)
    .padding(7)
    .background {
        RoundedRectangle(cornerRadius: 9)
            .foregroundColor(color)
            .opacity(0.12)
    }
}
