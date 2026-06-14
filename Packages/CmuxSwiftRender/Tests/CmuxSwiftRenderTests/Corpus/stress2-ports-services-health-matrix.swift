// ── Ports & Services Health Matrix ───────────────────────────────────
// A LazyVGrid of workspace cells. Each cell is a card whose accent color
// comes from a computed health *string* resolved through `switch`, with a
// horizontal ScrollView strip of capsule port chips, a ProgressView when
// the workspace is building, and a contextMenu of actions. Tap selects.

// Health is a single computed string per workspace; every visual decision
// (color, icon, label) switches on it. This is the spine of the sidebar.
func health(_ ws) -> String {
    if ws.progress.value > 0 { return "building" }
    if ws.dirty { return "dirty" }
    if ws.portCount >= 3 { return "busy" }
    if ws.portCount > 0 { return "serving" }
    if ws.unread > 0 { return "waiting" }
    return "idle"
}

func healthColor(_ h: String) -> String {
    switch h {
    case "building": return "#BF5AF2"
    case "busy":     return "#0A84FF"
    case "serving":  return "#34C759"
    case "dirty":    return "#FF9F0A"
    case "waiting":  return "#FF453A"
    default:         return "#48484A"
    }
}

func healthIcon(_ h: String) -> String {
    switch h {
    case "building": return "hammer.fill"
    case "busy":     return "bolt.horizontal.fill"
    case "serving":  return "dot.radiowaves.up.forward"
    case "dirty":    return "pencil.and.outline"
    case "waiting":  return "bell.badge.fill"
    default:         return "moon.zzz.fill"
    }
}

func healthLabel(_ h: String) -> String {
    switch h {
    case "building": return "building"
    case "busy":     return "busy"
    case "serving":  return "serving"
    case "dirty":    return "uncommitted"
    case "waiting":  return "needs you"
    default:         return "idle"
    }
}

// Classify a port number into a service family, used for chip color + tag.
func portFamily(_ p: Int) -> String {
    switch p {
    case 3000, 3001, 5173, 4321, 8081: return "web"
    case 8080, 8000, 4000, 9229:       return "api"
    case 80, 443, 8443:                return "https"
    case 5432, 3306, 27017, 6379:      return "data"
    default:
        if p >= 9000 { return "metrics" }
        return "tcp"
    }
}

func familyColor(_ f: String) -> String {
    switch f {
    case "web":     return "#0A84FF"
    case "api":     return "#5E5CE6"
    case "https":   return "#34C759"
    case "data":    return "#FF9F0A"
    case "metrics": return "#BF5AF2"
    default:        return "#64D2FF"
    }
}

func familyTag(_ p: Int) -> String {
    let f = portFamily(p)
    switch f {
    case "data":
        switch p {
        case 5432:  return "pg"
        case 3306:  return "sql"
        case 27017: return "mongo"
        case 6379:  return "redis"
        default:    return "db"
        }
    default: return f
    }
}

// One port chip: a colored Capsule with the port number and a derived
// family tag stacked beneath it. Tapping focuses the owning workspace.
func portChip(_ p: Int, _ wsId) -> some View {
    let c = familyColor(portFamily(p))
    return VStack(spacing: 1) {
        Text("\(p)")
            .font(.system(size: 11, design: .monospaced))
            .fontWeight(.semibold)
            .monospacedDigit()
            .foregroundColor("#FFFFFF")
        Text(familyTag(p))
            .font(.system(size: 6))
            .textCase(.uppercase)
            .foregroundColor("#FFFFFF")
            .opacity(0.75)
    }
    .padding(5)
    .frame(minWidth: 46)
    .background {
        Capsule()
            .fill(LinearGradient(colors: [c, "#000000"], startPoint: .top, endPoint: .bottom))
            .opacity(0.95)
            .overlay {
                Capsule().stroke(c, lineWidth: 1).opacity(0.6)
            }
    }
    .clipShape(Capsule())
    .shadow(color: c, radius: 3, x: 0, y: 1)
    .help("Port \(p) · \(familyTag(p))")
    .onTapGesture { cmux("workspace.select", workspace_id: wsId) }
}

// The horizontal strip of chips for one workspace, or a sleep hint.
func portStrip(_ ws) -> some View {
    ScrollView(.horizontal) {
        HStack(spacing: 5) {
            if ws.portCount > 0 {
                ForEach(ws.ports.sorted { $0 < $1 }) { p in
                    portChip(p, ws.id)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.tertiary)
                    Text("no listeners")
                        .font(.system(size: 10))
                        .italic()
                        .foregroundColor(.tertiary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(1)
    }
    .scrollIndicators(.hidden)
}

// One matrix cell: a rounded card whose accent + ring follow the health
// string, header with the health badge, the port strip, and an optional
// build ProgressView. The whole cell taps to select and has a contextMenu.
func cell(_ ws) -> some View {
    let h = health(ws)
    let c = healthColor(h)
    return VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 6) {
            Image(systemName: healthIcon(h))
                .font(.system(size: 11))
                .foregroundColor(c)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(ws.title)
                        .font(.system(size: 13))
                        .fontWeight(.semibold)
                        .foregroundColor(ws.selected ? "#FFFFFF" : "#E5E5EA")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if ws.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7))
                            .foregroundColor("#FF9F0A")
                            .rotationEffect(.degrees(40))
                    }
                }
                Text(healthLabel(h))
                    .font(.system(size: 8))
                    .textCase(.uppercase)
                    .fontWeight(.semibold)
                    .foregroundColor(c)
            }
            Spacer()
            Text("\(ws.portCount)")
                .font(.system(size: 12, design: .monospaced))
                .fontWeight(.bold)
                .monospacedDigit()
                .foregroundColor(ws.portCount > 0 ? c : "#8E8E93")
                .padding(4)
                .frame(minWidth: 24)
                .background {
                    Circle().fill(c).opacity(0.16)
                }
        }

        // Branch + dirty marker, only when the workspace exposes a branch.
        if let b = ws.branch {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8))
                    .foregroundColor(.tertiary)
                Text(b)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(ws.dirty ? "#FF9F0A" : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if ws.dirty {
                    Circle().fill("#FF9F0A").frame(width: 4, height: 4)
                }
            }
        }

        portStrip(ws)

        // Build progress rides in only while compiling.
        if ws.progress.value > 0 {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(ws.progress.label)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text("\((ws.progress.value).formatted(.percent))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor("#BF5AF2")
                }
                ProgressView(value: ws.progress.value, total: 1.0)
                    .tint("#BF5AF2")
            }
        }

        // Footer meta line: tab count + unread badge.
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 8))
                    .foregroundColor(.tertiary)
                Text("\(ws.tabCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.tertiary)
            }
            Spacer()
            if ws.unread > 0 {
                Text("\(ws.unread)")
                    .font(.system(size: 8))
                    .fontWeight(.bold)
                    .foregroundColor("#FFFFFF")
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background { Capsule().fill("#FF453A") }
            }
        }
    }
    .padding(9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
        RoundedRectangle(cornerRadius: 12)
            .fill(LinearGradient(
                colors: [ws.selected ? c : "#1C1C1E", "#1C1C1E"],
                startPoint: .topLeading,
                endPoint: .bottomTrailing))
            .opacity(ws.selected ? 0.28 : 0.6)
    }
    .overlay {
        RoundedRectangle(cornerRadius: 12)
            .stroke(c, lineWidth: ws.selected ? 1.5 : 0.75)
            .opacity(ws.selected ? 0.9 : 0.35)
    }
    .overlay(alignment: .topTrailing) {
        if health(ws) == "building" {
            ProgressView()
                .scaleEffect(0.5)
                .padding(4)
        }
    }
    .onTapGesture { cmux("workspace.select", workspace_id: ws.id) }
    .contextMenu {
        Button(action: { cmux("workspace.select", workspace_id: ws.id) }) {
            Label("Focus workspace", systemName: "scope")
        }
        if let pr = ws.pr {
            Button(action: { cmux("open.url", url: pr.url) }) {
                Label("PR \(pr.label)", systemName: "arrow.triangle.pull")
            }
        }
        Button(action: { cmux("workspace.select", workspace_id: ws.id) }) {
            Label("\(ws.portCount) ports", systemName: "network")
        }
    }
}

// A small legend chip mapping a health string to its color.
func legendChip(_ h: String) -> some View {
    HStack(spacing: 4) {
        Circle().fill(healthColor(h)).frame(width: 7, height: 7)
        Text(healthLabel(h))
            .font(.system(size: 9))
            .foregroundColor(.secondary)
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background {
        Capsule().fill(healthColor(h)).opacity(0.12)
    }
}

// ── Derived aggregates over the live workspace set ───────────────────
let states = ["building", "busy", "serving", "dirty", "waiting", "idle"]
let allPorts = workspaces.flatMap { $0.ports }
let totalPorts = allPorts.count
let serving = workspaces.filter { $0.portCount > 0 }.count
let building = workspaces.filter { $0.progress.value > 0 }.count
let families = ["web", "api", "https", "data", "metrics", "tcp"]
let famCount = families.map { f in allPorts.filter { portFamily($0) == f }.count }
let busiest = workspaces.sorted { $0.portCount > $1.portCount }.first

// Order cells by health severity, then by port count, so live work floats up.
func rank(_ ws) -> Int {
    switch health(ws) {
    case "building": return 0
    case "waiting":  return 1
    case "dirty":    return 2
    case "busy":     return 3
    case "serving":  return 4
    default:         return 5
    }
}
let ordered = workspaces.sorted { rank($0) < rank($1) }

// ── Root ─────────────────────────────────────────────────────────────
ScrollView {
    VStack(alignment: .leading, spacing: 12) {
        // Header: title + the global port count, with a service-family
        // distribution bar built from stacked capsules.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "square.grid.2x2.fill")
                    .imageScale(.large)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor("#0A84FF")
                VStack(alignment: .leading, spacing: 0) {
                    Text("Services")
                        .font(.title)
                        .bold()
                        .foregroundColor("#FFFFFF")
                    Text("\(serving) serving · \(building) building")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(totalPorts)")
                        .font(.system(size: 26, design: .monospaced))
                        .bold()
                        .monospacedDigit()
                        .foregroundColor("#34C759")
                    Text("PORTS")
                        .font(.system(size: 8))
                        .textCase(.uppercase)
                        .foregroundColor(.tertiary)
                }
            }

            // Family distribution bar: one segment per family, width by share.
            if totalPorts > 0 {
                HStack(spacing: 2) {
                    ForEach(families.indices) { i in
                        let f = families[i]
                        let n = famCount[i]
                        if n > 0 {
                            Capsule()
                                .fill(familyColor(f))
                                .frame(height: 8)
                                .layoutPriority(Double(n))
                                .help("\(f): \(n)")
                        }
                    }
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(families.indices) { i in
                            if famCount[i] > 0 {
                                HStack(spacing: 3) {
                                    Circle().fill(familyColor(families[i])).frame(width: 6, height: 6)
                                    Text("\(families[i]) \(famCount[i])")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            // Busiest workspace callout, only when one exists with ports.
            if let top = busiest {
                if top.portCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 10))
                            .foregroundColor("#FF9F0A")
                        Text("Busiest")
                            .font(.system(size: 9))
                            .textCase(.uppercase)
                            .foregroundColor(.tertiary)
                        Text(top.title)
                            .font(.system(size: 11))
                            .fontWeight(.semibold)
                            .foregroundColor("#FFFFFF")
                            .lineLimit(1)
                        Spacer()
                        Text("\(top.portCount) ports")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor("#FF9F0A")
                    }
                    .padding(7)
                    .background {
                        RoundedRectangle(cornerRadius: 9)
                            .fill("#FF9F0A")
                            .opacity(0.1)
                    }
                }
            }

            // Health legend.
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(states) { s in
                        legendChip(s)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }

        Divider().opacity(0.3)

        // The matrix itself.
        if ordered.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "tray").foregroundColor(.tertiary)
                Text("No workspaces")
                    .font(.caption)
                    .foregroundColor(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        } else {
            LazyVGrid(columns: 1, spacing: 9) {
                ForEach(ordered) { ws in
                    cell(ws)
                }
            }
        }
    }
    .padding(10)
}