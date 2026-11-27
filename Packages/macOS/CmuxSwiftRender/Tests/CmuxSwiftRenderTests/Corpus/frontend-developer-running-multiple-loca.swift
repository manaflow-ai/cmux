HSplitView {
    // LEFT: per-project health, one row per workspace
    VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 6) {
            Image(systemName: "square.split.2x1")
                .foregroundColor(.blue)
            Text("Projects")
                .font(.headline)
                .bold()
            Spacer()
            Text("\(workspaceCount)")
                .font(.caption)
                .foregroundColor("#8E8E93")
        }
        Divider()

        ForEach(workspaces) { ws in
            VStack(alignment: .leading, spacing: 4) {
                Button(action: {
                    cmux("workspace.select", workspace_id: ws.id)
                    log("focus project \(ws.title)")
                }) {
                    HStack(spacing: 6) {
                        // selected dot vs idle dot
                        if ws.selected {
                            Image(systemName: "largecircle.fill.circle")
                                .foregroundColor("#34C759")
                        } else {
                            Image(systemName: "circle")
                                .foregroundColor("#48484A")
                        }
                        Text(ws.title)
                            .fontWeight(.semibold)
                            .foregroundColor(ws.selected ? "#FFFFFF" : "#C7C7CC")
                        Spacer()
                        // tab count proxies "how many panes / servers running"
                        Text("\(ws.tabs.count) tab")
                            .font(.caption)
                            .foregroundColor("#8E8E93")
                    }
                }
                // health line derived from CI/lint/test state for this project's branch
                HStack(spacing: 6) {
                    Image(systemName: health(ws).icon)
                        .foregroundColor(health(ws).color)
                    Text(health(ws).label)
                        .font(.caption)
                        .foregroundColor(health(ws).color)
                    Spacer()
                    Text(gitSummary(ws))
                        .font(.caption)
                        .foregroundColor("#8E8E93")
                }
                .padding(2)

                // tabs as quick-jump chips
                if !ws.tabs.isEmpty {
                    ForEach(ws.tabs) { tab in
                        Button(action: {
                            cmux("surface.focus", surface_id: tab.id)
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: tab.focused ? "chevron.right.circle.fill" : "terminal")
                                    .foregroundColor(tab.focused ? "#0A84FF" : "#636366")
                                Text(tab.title)
                                    .font(.caption)
                                    .foregroundColor(tab.focused ? "#FFFFFF" : "#AEAEB2")
                                Spacer()
                                // live port + server status for this pane
                                Text(serverStatus(tab))
                                    .font(.caption)
                                    .foregroundColor(serverColor(tab))
                            }
                            .padding(2)
                        }
                    }
                }
                Divider()
            }
        }
        Spacer()
    }
    .padding(12)

    // RIGHT: "what needs me" triage feed
    VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 6) {
            Image(systemName: "bell.badge")
                .foregroundColor("#FF9F0A")
            Text("Needs you")
                .font(.headline)
                .bold()
            Spacer()
            // relative time since last refresh, auto-updating
            Text("updated \(relativeTime(lastRefresh))")
                .font(.caption)
                .foregroundColor("#8E8E93")
        }
        Divider()

        // --- DEV SERVERS ---
        Text("DEV SERVERS")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor("#8E8E93")
        ForEach(devServers) { srv in
            Button(action: { cmux("surface.focus", surface_id: srv.surfaceId) }) {
                HStack(spacing: 8) {
                    Image(systemName: srv.up ? "bolt.fill" : "bolt.slash")
                        .foregroundColor(srv.up ? "#34C759" : "#FF453A")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(srv.name)
                            .fontWeight(.semibold)
                            .foregroundColor("#FFFFFF")
                        Text("localhost:\(srv.port) · \(srv.hmrAge)")
                            .font(.caption)
                            .foregroundColor("#8E8E93")
                    }
                    Spacer()
                    // open in browser without leaving the keyboard
                    Button("Open") { openURL("http://localhost:\(srv.port)") }
                        .font(.caption)
                        .foregroundColor("#0A84FF")
                }
                .padding(4)
            }
        }
        Divider()

        // --- CHECKS (lint / typecheck / test) ---
        Text("CHECKS")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor("#8E8E93")
        ForEach(checks) { c in
            HStack(spacing: 8) {
                Image(systemName: c.passing ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .foregroundColor(c.passing ? "#34C759" : "#FF453A")
                Text(c.name)
                    .foregroundColor("#FFFFFF")
                Spacer()
                Text(c.passing ? "\(c.passed) passed" : "\(c.failed) failed")
                    .font(.caption)
                    .foregroundColor(c.passing ? "#34C759" : "#FF453A")
            }
            .padding(3)
            .onTapGesture { cmux("surface.focus", surface_id: c.surfaceId) }
        }
        Divider()

        // --- PULL REQUESTS ---
        Text("PULL REQUESTS")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor("#8E8E93")
        ForEach(pulls) { pr in
            Button(action: { openURL(pr.url) }) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: prIcon(pr))
                        .foregroundColor(prColor(pr))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("#\(pr.number) \(pr.title)")
                            .foregroundColor("#FFFFFF")
                        HStack(spacing: 8) {
                            Text(pr.ciState)
                                .font(.caption)
                                .foregroundColor(pr.ciGreen ? "#34C759" : "#FF453A")
                            Text(pr.reviewState)
                                .font(.caption)
                                .foregroundColor("#FF9F0A")
                            if pr.unresolved > 0 {
                                Text("\(pr.unresolved) threads")
                                    .font(.caption)
                                    .foregroundColor("#FF9F0A")
                            }
                        }
                    }
                    Spacer()
                }
                .padding(4)
            }
        }
        Spacer()
    }
    .padding(12)
}
