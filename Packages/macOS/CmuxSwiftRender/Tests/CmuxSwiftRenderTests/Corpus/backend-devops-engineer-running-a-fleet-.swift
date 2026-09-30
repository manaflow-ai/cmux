HSplitView {
    // ===== LEFT: local services =====
    VStack(alignment: .leading, spacing: 10) {

        // --- header: up/total summary ---
        HStack {
            Image(systemName: "server.rack")
            Text("Services").font(.headline).bold()
            Spacer()
            Text("\(services.filter { $0.up }.count)/\(services.count) up")
                .font(.caption)
                .foregroundColor(services.allUp ? "#34C759" : "#FF9F0A")
        }

        Divider()

        // --- one row per service ---
        ForEach(services) { svc in
            HStack(spacing: 8) {
                // health dot, colored by status
                Text("●")
                    .foregroundColor(svc.up ? (svc.healthy ? "#34C759" : "#FF9F0A") : "#FF453A")

                VStack(alignment: .leading, spacing: 1) {
                    Text(svc.name).fontWeight(.semibold)
                    HStack(spacing: 6) {
                        Image(systemName: "network")
                        Text(":\(svc.port)").font(.caption).foregroundColor("#8E8E93")
                        Text(svc.up ? "\(svc.latencyMs)ms" : "down")
                            .font(.caption)
                            .foregroundColor(svc.up ? "#8E8E93" : "#FF453A")
                    }
                }

                Spacer()

                // restart
                Button(action: { cmux("service.restart", service_id: svc.id) }) {
                    Image(systemName: "arrow.clockwise")
                }
                // tail logs (focuses/opens the service's log surface)
                Button(action: { cmux("surface.focus", surface_id: svc.logSurfaceId) }) {
                    Image(systemName: "text.alignleft")
                }
            }
            .padding(4)
            .onTapGesture { cmux("service.open", service_id: svc.id) }
        }

        Divider()

        // --- ports in use, quick scan ---
        Text("Ports").font(.caption).bold().foregroundColor("#8E8E93")
        ForEach(ports) { p in
            HStack {
                Text(":\(p.port)").fontWeight(.semibold)
                Text(p.owner).font(.caption).foregroundColor("#8E8E93")
                Spacer()
                Button(action: { cmux("port.kill", port: p.port) }) {
                    Image(systemName: "xmark.circle").foregroundColor("#FF453A")
                }
            }
            .padding(2)
        }

        Spacer()

        // --- danger zone ---
        Divider()
        Text("Danger zone").font(.caption).bold().foregroundColor("#FF453A")
        HStack(spacing: 8) {
            Button("Restart all") { cmux("service.restartAll") }
                .foregroundColor("#FF9F0A")
            Button("Stop all") { cmux("service.stopAll") }
                .foregroundColor("#FF453A")
        }
    }
    .padding(10)

    // ===== RIGHT: pipeline =====
    VStack(alignment: .leading, spacing: 10) {

        // --- git context ---
        HStack {
            Image(systemName: "arrow.triangle.branch")
            Text(git.branch).fontWeight(.semibold)
            if git.dirty {
                Text("●").foregroundColor("#FF9F0A")
                Text("\(git.changedFiles) changed").font(.caption).foregroundColor("#FF9F0A")
            } else {
                Text("clean").font(.caption).foregroundColor("#34C759")
            }
            Spacer()
            Text("↑\(git.ahead) ↓\(git.behind)").font(.caption).foregroundColor("#8E8E93")
        }

        Divider()

        // --- CI build status ---
        HStack(spacing: 8) {
            Text("●").foregroundColor(
                build.status == "passing" ? "#34C759" :
                build.status == "running" ? "#FF9F0A" : "#FF453A"
            )
            VStack(alignment: .leading, spacing: 1) {
                Text("CI: \(build.status)").fontWeight(.semibold)
                Text("\(build.sha) · \(build.durationSec)s").font(.caption).foregroundColor("#8E8E93")
            }
            Spacer()
            Button(action: { cmux("ci.rerun", run_id: build.runId) }) {
                Image(systemName: "arrow.clockwise")
            }
            Button(action: { cmux("ci.open", run_id: build.runId) }) {
                Image(systemName: "arrow.up.forward.square")
            }
        }

        Divider()

        // --- deploy targets ---
        Text("Deploy").font(.headline).bold()
        ForEach(deploys) { d in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("●").foregroundColor(
                        d.state == "live" ? "#34C759" :
                        d.state == "deploying" ? "#FF9F0A" : "#FF453A"
                    )
                    Text(d.env).fontWeight(.semibold)
                    Spacer()
                    Text(d.relativeTime).font(.caption).foregroundColor("#8E8E93")
                }
                HStack {
                    Text(d.version).font(.caption).foregroundColor("#8E8E93")
                    Spacer()
                    Button(d.env == "prod" ? "Ship prod" : "Deploy") {
                        cmux("deploy.start", env: d.env, sha: build.sha)
                    }
                    .foregroundColor(d.env == "prod" ? "#FF453A" : "#0A84FF")
                    .bold()
                }
            }
            .padding(6)
        }

        Divider()

        // --- recent deploy log tail ---
        Text("Recent log").font(.caption).bold().foregroundColor("#8E8E93")
        ForEach(deployLog) { line in
            HStack(spacing: 6) {
                Text(line.level == "error" ? "✗" : line.level == "warn" ? "!" : "·")
                    .foregroundColor(
                        line.level == "error" ? "#FF453A" :
                        line.level == "warn" ? "#FF9F0A" : "#8E8E93"
                    )
                Text(line.text).font(.caption).foregroundColor(line.level == "error" ? "#FF453A" : "#C7C7CC")
            }
        }

        Spacer()
    }
    .padding(10)
}
