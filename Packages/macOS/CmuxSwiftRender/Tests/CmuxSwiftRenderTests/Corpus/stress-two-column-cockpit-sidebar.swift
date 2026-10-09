// Two-column cockpit: workspace rail (left) + selected-workspace tab deck (right).

func pad2(_ n: Int) -> String {
    return n < 10 ? "0\(n)" : "\(n)"
}

func clockLabel() -> String {
    return "\(pad2(clock.hour)):\(pad2(clock.minute)):\(pad2(clock.second))"
}

func unreadColor(_ n: Int) -> String {
    if n == 0 { return "#3a3f4b" }
    if n < 3 { return "#3b82f6" }
    if n < 8 { return "#f59e0b" }
    return "#ef4444"
}

func statusColor(_ s: String) -> String {
    if s == "open" { return "#22c55e" }
    if s == "merged" { return "#a855f7" }
    if s == "draft" { return "#9ca3af" }
    if s == "closed" { return "#ef4444" }
    return "#64748b"
}

func dotColor(_ ws: Any) -> String {
    return ws.unread > 0 ? unreadColor(ws.unread) : (ws.dirty == true ? "#f59e0b" : "#22c55e")
}

// ---- small reusable view helpers ----

func unreadBadge(_ n: Int) -> some View {
    return ZStack {
        Capsule()
            .foregroundColor(unreadColor(n))
            .frame(width: n > 9 ? 24 : 18, height: 16)
        Text(n > 99 ? "99+" : "\(n)")
            .font(.system(size: 10))
            .bold()
            .foregroundColor("#0b0d12")
    }
    .opacity(n == 0 ? 0 : 1)
    .shadow(radius: 4, x: 0, y: 0, color: unreadColor(n))
}

func portChips(_ ports: [Int]) -> some View {
    return ScrollView(.horizontal) {
        HStack(spacing: 4) {
            ForEach(ports.prefix(6)) { p in
                Text("\(p)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor("#7dd3fc")
                    .padding(3)
                    .background("#0e2230")
                    .cornerRadius(4)
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .foregroundColor("#22c55e")
                            .frame(width: 4, height: 4)
                            .offset(x: 2, y: -2)
                    }
            }
            if ports.count > 6 {
                Text("+\(ports.count - 6)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }
    .scrollIndicators(.hidden)
}

func prPill(_ ws: Any) -> some View {
    return Group {
        if ws.pr != nil {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.pull")
                    .imageScale(.small)
                    .symbolRenderingMode(.hierarchical)
                Text("#\(ws.pr.number)")
                    .font(.system(size: 10, design: .monospaced))
                    .bold()
                if ws.pr.stale == true {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                        .foregroundColor("#f59e0b")
                }
            }
            .foregroundColor(statusColor(ws.pr.status))
            .padding(3)
            .overlay(alignment: .center) {
                Capsule()
                    .foregroundColor("#00000000")
                    .border(.gray, width: 0)
            }
            .background {
                Capsule().foregroundStyle(statusColor(ws.pr.status)).opacity(0.16)
            }
            .help("PR \(ws.pr.label)")
            .onTapGesture { cmux("openURL", param: ws.pr.url) }
        } else {
            Spacer().frame(width: 0, height: 0)
        }
    }
}

// ---- LEFT RAIL: a single workspace row ----

func railRow(_ ws: Any) -> some View {
    return HStack(spacing: 8) {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .foregroundColor(ws.selected ? "#3b82f6" : dotColor(ws))
                .frame(width: 3, height: ws.selected ? 34 : 22)
            if ws.pinned {
                Image(systemName: "pin.fill")
                    .imageScale(.small)
                    .foregroundColor("#f59e0b")
                    .offset(x: 0, y: -18)
            }
        }
        .frame(width: 8)

        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text(ws.title)
                    .font(.system(size: 12))
                    .fontWeight(ws.selected ? .semibold : .regular)
                    .foregroundColor(ws.selected ? "#e8edf5" : "#aab3c2")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                unreadBadge(ws.unread)
            }
            HStack(spacing: 5) {
                Image(systemName: "rectangle.split.3x1")
                    .imageScale(.small)
                    .foregroundColor(.tertiary)
                Text("\(ws.tabCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                if ws.branch != nil {
                    Text(ws.branch)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(ws.dirty == true ? "#f59e0b" : "#6b7280")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if ws.dirty == true {
                        Circle().foregroundColor("#f59e0b").frame(width: 5, height: 5)
                    }
                }
                Spacer()
                if ws.portCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.horizontal.fill")
                            .imageScale(.small)
                            .foregroundColor("#7dd3fc")
                        Text("\(ws.portCount)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor("#7dd3fc")
                    }
                }
            }
            if ws.progress != nil {
                ProgressView(value: ws.progress.value, total: 1.0)
                    .tint(ws.selected ? "#3b82f6" : "#4b5563")
            }
        }
    }
    .padding(7)
    .background {
        RoundedRectangle(cornerRadius: 8)
            .foregroundStyle(ws.selected ? "#1b2433" : "#0f141d")
            .overlay(alignment: .center) {
                RoundedRectangle(cornerRadius: 8)
                    .foregroundColor("#00000000")
                    .border(ws.selected ? "#2c3f5e" : "#161c27", width: 1)
            }
    }
    .overlay(alignment: .topTrailing) {
        if ws.remote != nil && ws.remote.connected == true {
            Image(systemName: "wifi")
                .imageScale(.small)
                .foregroundColor("#22c55e")
                .padding(4)
        }
    }
    .contextMenu {
        Button("Focus") { cmux("workspace.focus", param: ws.id) }
        Button(ws.pinned ? "Unpin" : "Pin") { cmux("workspace.togglePin", param: ws.id) }
        Button("Mark read") { cmux("workspace.markRead", param: ws.id) }
    }
    .help(ws.directory)
    .onTapGesture { cmux("workspace.select", param: ws.id) }
}

// ---- RIGHT DECK: one tab card ----

func tabCard(_ tab: Any) -> some View {
    return HStack(spacing: 9) {
        ZStack {
            Circle()
                .foregroundStyle(tab.focused ? "#3b82f6" : "#1c2433")
                .frame(width: 26, height: 26)
            Image(systemName: tab.pinned ? "pin.fill" : "terminal.fill")
                .imageScale(.small)
                .foregroundColor(tab.focused ? "#0b0d12" : "#7c8699")
        }
        .overlay(alignment: .topTrailing) {
            if tab.dirty == true {
                Circle().foregroundColor("#f59e0b").frame(width: 7, height: 7).offset(x: 2, y: -2)
            }
        }

        VStack(spacing: 2) {
            Text(tab.title)
                .font(.system(size: 12))
                .fontWeight(tab.focused ? .semibold : .regular)
                .foregroundColor(tab.focused ? "#e8edf5" : "#9aa4b4")
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 6) {
                if tab.directory != nil {
                    Text(tab.directory)
                        .font(.system(size: 10))
                        .fontDesign(.monospaced)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if tab.branch != nil {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").imageScale(.small)
                        Text(tab.branch).font(.system(size: 9, design: .monospaced))
                    }
                    .foregroundColor(tab.dirty == true ? "#f59e0b" : "#6b7280")
                }
            }
        }
        Spacer()
        if tab.ports != nil && tab.ports.count > 0 {
            Text(":\(tab.ports.first)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor("#7dd3fc")
                .padding(3)
                .background("#0e2230")
                .cornerRadius(4)
        }
    }
    .padding(8)
    .background {
        UnevenRoundedRectangle(cornerRadius: 9)
            .foregroundStyle(tab.focused ? "#16243a" : "#0d121b")
    }
    .overlay(alignment: .center) {
        if tab.focused {
            RoundedRectangle(cornerRadius: 9)
                .foregroundColor("#00000000")
                .border("#3b82f6", width: 1)
        }
    }
    .overlay(alignment: .leading) {
        RoundedRectangle(cornerRadius: 2)
            .foregroundColor(tab.focused ? "#3b82f6" : "#00000000")
            .frame(width: 3, height: 28)
    }
    .contextMenu {
        Button("Focus tab") { cmux("tab.focus", param: tab.id) }
        Button(tab.pinned ? "Unpin tab" : "Pin tab") { cmux("tab.togglePin", param: tab.id) }
        Button("Close tab") { cmux("tab.close", param: tab.id) }
    }
    .onTapGesture { cmux("tab.focus", param: tab.id) }
}

// ---- header strip shared across both columns ----

func cockpitHeader() -> some View {
    return HStack(spacing: 8) {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .foregroundStyle("#3b82f6")
                .frame(width: 26, height: 26)
                .shadow(radius: 6, x: 0, y: 0, color: "#3b82f6")
            Image(systemName: "square.split.2x1.fill")
                .imageScale(.small)
                .foregroundColor("#0b0d12")
        }
        VStack(spacing: 0) {
            Text("COCKPIT")
                .font(.system(size: 11))
                .bold()
                .textCase(.uppercase)
                .foregroundColor("#e8edf5")
            Text("\(workspaceCount) ws / \(unreadTotal) unread")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
        }
        Spacer()
        Menu("•••") {
            Button("Collapse all reads") { cmux("workspace.markAllRead") }
            Button("New workspace") { cmux("workspace.create") }
            Section("Sort") {
                Button("By unread") { cmux("workspace.sort", param: "unread") }
                Button("By recent") { cmux("workspace.sort", param: "recent") }
            }
        }
        .foregroundColor(.secondary)
        Text(clockLabel())
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor("#7dd3fc")
    }
    .padding(8)
    .background {
        UnevenRoundedRectangle(cornerRadius: 0)
            .foregroundStyle("#0b0f17")
    }
    .overlay(alignment: .bottom) {
        Rectangle().foregroundColor("#1b2433").frame(maxWidth: .infinity, height: 1)
    }
}

// ---- ROOT ----

let sorted = workspaces.sorted { $0.unread > $1.unread }
let selected = workspaces.first { $0.selected }
let selTabs = selected != nil ? selected.tabs : []
let focusedTabCount = selTabs.filter { $0.focused }.count
let totalPorts = workspaces.reduce(0) { $0 + $1.portCount }

VStack(spacing: 0) {
    cockpitHeader()

    HSplitView {
        // ===== LEFT: workspace rail =====
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle").imageScale(.small).foregroundColor(.secondary)
                Text("WORKSPACES")
                    .font(.system(size: 9)).bold().textCase(.uppercase)
                    .foregroundColor(.secondary)
                Spacer()
                Gauge(value: workspaceCount > 0 ? Double(unreadTotal) / Double(max(unreadTotal, workspaceCount)) : 0) {
                    Text("u")
                }
                .tint("#f59e0b")
                .scaleEffect(0.55)
            }
            .padding(7)

            ScrollView {
                Reorderable(workspaces, move: "workspace.reorder") { ws in
                    railRow(ws)
                }
            }
            .scrollIndicators(.hidden)

            Divider()
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.horizontal.fill").imageScale(.small).foregroundColor("#7dd3fc")
                    Text("\(totalPorts)").font(.system(size: 10, design: .monospaced)).foregroundColor("#7dd3fc")
                }
                Spacer()
                ForEach(sorted.prefix(5)) { ws in
                    Circle()
                        .foregroundColor(dotColor(ws))
                        .frame(width: 7, height: 7)
                        .opacity(ws.selected ? 1 : 0.6)
                }
            }
            .padding(7)
        }
        .frame(minWidth: 168, maxWidth: .infinity, alignment: .leading)
        .background("#0c1019")

        // ===== RIGHT: selected workspace tab deck =====
        VStack(spacing: 0) {
            // workspace meta banner
            Group {
                if selected != nil {
                    VStack(spacing: 6) {
                        HStack(spacing: 7) {
                            Circle().foregroundColor(dotColor(selected)).frame(width: 9, height: 9)
                            Text(selected.title)
                                .font(.system(size: 13)).bold()
                                .foregroundColor("#e8edf5")
                                .lineLimit(1).truncationMode(.tail)
                            Spacer()
                            prPill(selected)
                        }
                        HStack(spacing: 5) {
                            Image(systemName: "folder.fill").imageScale(.small).foregroundColor(.tertiary)
                            Text(selected.directory)
                                .font(.system(size: 10))
                                .fontDesign(.monospaced)
                                .foregroundColor("#8b94a3")
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if selected.portCount > 0 {
                            portChips(selected.ports)
                        }
                        if selected.latestMessage != nil {
                            HStack(spacing: 5) {
                                Image(systemName: "text.bubble.fill")
                                    .imageScale(.small)
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundColor("#3b82f6")
                                Text(selected.latestMessage)
                                    .font(.system(size: 10))
                                    .italic()
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background { RoundedRectangle(cornerRadius: 7).foregroundStyle("#10151f") }
                        }
                    }
                    .padding(9)
                    .background {
                        UnevenRoundedRectangle(cornerRadius: 0).foregroundStyle("#0d121c")
                    }
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .foregroundColor(selected.color != nil ? selected.color : "#3b82f6")
                            .frame(width: 3)
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "square.dashed")
                            .imageScale(.large)
                            .foregroundColor(.tertiary)
                        Text("No workspace selected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, height: 80)
                }
            }

            // tab deck header
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack.fill").imageScale(.small).foregroundColor(.secondary)
                Text("TABS")
                    .font(.system(size: 9)).bold().textCase(.uppercase).foregroundColor(.secondary)
                Text("\(selTabs.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor("#7dd3fc")
                    .padding(2)
                    .background("#0e2230")
                    .cornerRadius(4)
                Spacer()
                if focusedTabCount > 0 {
                    HStack(spacing: 3) {
                        Circle().foregroundColor("#3b82f6").frame(width: 6, height: 6)
                        Text("\(focusedTabCount) focused")
                            .font(.system(size: 9)).foregroundColor("#7dd3fc")
                    }
                }
                Button("+") { cmux("tab.create", param: selectedId) }
                    .foregroundColor(.secondary)
                    .disabled(selected == nil)
            }
            .padding(7)
            .overlay(alignment: .bottom) {
                Rectangle().foregroundColor("#161c27").frame(maxWidth: .infinity, height: 1)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    if selTabs.count == 0 {
                        Text("This workspace has no tabs.")
                            .font(.caption)
                            .foregroundColor(.tertiary)
                            .padding(14)
                            .redacted(reason: .placeholder)
                    } else {
                        ForEach(Array(selTabs.enumerated()), id: \.offset) { i, tab in
                            HStack(spacing: 8) {
                                Text(pad2(i + 1))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.tertiary)
                                    .frame(width: 18)
                                tabCard(tab)
                            }
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.hidden)

            // bottom status bar
            Divider()
            HStack(spacing: 8) {
                Text(selectedTitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text("idx \(selected != nil ? selected.index : 0)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.tertiary)
                Circle()
                    .foregroundColor(selected != nil && selected.remote != nil && selected.remote.connected == true ? "#22c55e" : "#3a3f4b")
                    .frame(width: 7, height: 7)
            }
            .padding(7)
        }
        .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
        .background("#0a0e16")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
.background("#080b11")