HSplitView {
    // LEFT COLUMN: scheme + destination control surface
    VStack(alignment: .leading, spacing: 14) {

        // --- Active scheme header ---
        HStack(spacing: 8) {
            Image(systemName: "hammer.fill")
                .foregroundColor("#34C759")
            VStack(alignment: .leading, spacing: 2) {
                Text("SCHEME")
                    .font(.caption)
                    .foregroundColor("#8E8E93")
                Text(activeScheme)
                    .font(.headline)
                    .bold()
            }
            Spacer()
            // Quick config toggle (Debug/Release) shown as a tappable pill
            Text(activeConfig)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor("#0A84FF")
                .padding(6)
                .onTapGesture {
                    // Cycle Debug -> Release. Needs local mutable state + a way
                    // to write back a build config; modeled as a cmux action.
                    cmux("ios.config.cycle", current: activeConfig)
                }
        }

        Divider()

        // --- Scheme switcher ---
        Text("Switch scheme")
            .font(.caption)
            .foregroundColor("#8E8E93")
        let schemes = ["cmux", "cmux DEV", "cmuxUITests", "CMUXMobileSyncCore"]
        ForEach(schemes) { scheme in
            HStack(spacing: 8) {
                Image(systemName: scheme == activeScheme ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(scheme == activeScheme ? "#0A84FF" : "#8E8E93")
                Text(scheme)
                    .fontWeight(scheme == activeScheme ? .semibold : .regular)
                Spacer()
            }
            .padding(4)
            .onTapGesture {
                cmux("ios.scheme.select", scheme: scheme)
            }
        }

        Divider()

        // --- Destinations: simulators ---
        Text("SIMULATORS")
            .font(.caption)
            .bold()
            .foregroundColor("#8E8E93")
        let sims = [
            ["name": "iPhone 16 Pro", "os": "18.4", "state": "Booted"],
            ["name": "iPhone 16", "os": "18.4", "state": "Shutdown"],
            ["name": "iPhone SE (3rd gen)", "os": "18.4", "state": "Shutdown"],
            ["name": "iPad Pro 13\"", "os": "18.4", "state": "Shutdown"]
        ]
        ForEach(sims) { sim in
            HStack(spacing: 8) {
                Image(systemName: sim["state"] == "Booted" ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3")
                    .foregroundColor(sim["state"] == "Booted" ? "#34C759" : "#8E8E93")
                VStack(alignment: .leading, spacing: 1) {
                    Text(sim["name"])
                    Text("iOS \(sim["os"]) · \(sim["state"])")
                        .font(.caption)
                        .foregroundColor(sim["state"] == "Booted" ? "#34C759" : "#8E8E93")
                }
                Spacer()
                // Boot the sim straight from the row when it's shut down
                if sim["state"] != "Booted" {
                    Image(systemName: "play.circle.fill")
                        .foregroundColor("#0A84FF")
                        .onTapGesture {
                            cmux("ios.sim.boot", name: sim["name"], os: sim["os"])
                        }
                }
            }
            .padding(4)
            .onTapGesture {
                cmux("ios.destination.select", name: sim["name"], os: sim["os"], kind: "simulator")
            }
        }

        Divider()

        // --- Destinations: physical devices ---
        Text("DEVICES")
            .font(.caption)
            .bold()
            .foregroundColor("#8E8E93")
        let devices = [
            ["name": "Aziz iPhone 15 Pro", "os": "18.3.1", "state": "Connected"],
            ["name": "Test iPad mini", "os": "17.6", "state": "Unavailable"]
        ]
        ForEach(devices) { dev in
            HStack(spacing: 8) {
                Image(systemName: dev["state"] == "Connected" ? "iphone" : "iphone.slash")
                    .foregroundColor(dev["state"] == "Connected" ? "#34C759" : "#FF453A")
                VStack(alignment: .leading, spacing: 1) {
                    Text(dev["name"])
                    Text("iOS \(dev["os"]) · \(dev["state"])")
                        .font(.caption)
                        .foregroundColor("#8E8E93")
                }
                Spacer()
            }
            .padding(4)
            .onTapGesture {
                if dev["state"] == "Connected" {
                    cmux("ios.destination.select", name: dev["name"], os: dev["os"], kind: "device")
                } else {
                    log("Device \(dev["name"]) is unavailable")
                }
            }
        }
    }
    .padding(12)

    // RIGHT COLUMN: actions + workspace
    VStack(alignment: .leading, spacing: 14) {

        // --- Primary build actions ---
        Text("BUILD")
            .font(.caption)
            .bold()
            .foregroundColor("#8E8E93")

        HStack(spacing: 8) {
            // Build
            Button(action: { cmux("ios.build", scheme: activeScheme, config: activeConfig) }) {
                VStack(spacing: 4) {
                    Image(systemName: "hammer.fill")
                    Text("Build").font(.caption)
                }
                .padding(10)
                .foregroundColor("#FFFFFF")
                .background(Color(hex: "#0A84FF"))
                .cornerRadius(10)
            }
            // Run (build + install + launch on selected destination)
            Button(action: { cmux("ios.run", scheme: activeScheme, config: activeConfig) }) {
                VStack(spacing: 4) {
                    Image(systemName: "play.fill")
                    Text("Run").font(.caption)
                }
                .padding(10)
                .foregroundColor("#FFFFFF")
                .background(Color(hex: "#34C759"))
                .cornerRadius(10)
            }
        }

        HStack(spacing: 8) {
            Button(action: { cmux("ios.test", scheme: activeScheme) }) {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.diamond.fill")
                    Text("Test").font(.caption)
                }
                .padding(10)
                .foregroundColor("#FFFFFF")
                .background(Color(hex: "#5E5CE6"))
                .cornerRadius(10)
            }
            Button(action: { cmux("ios.clean", scheme: activeScheme) }) {
                VStack(spacing: 4) {
                    Image(systemName: "trash.fill")
                    Text("Clean").font(.caption)
                }
                .padding(10)
                .foregroundColor("#FFFFFF")
                .background(Color(hex: "#FF453A"))
                .cornerRadius(10)
            }
            // Stop the currently running app/sim session
            Button(action: { cmux("ios.stop") }) {
                VStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                    Text("Stop").font(.caption)
                }
                .padding(10)
                .foregroundColor("#FFFFFF")
                .background(Color(hex: "#8E8E93"))
                .cornerRadius(10)
            }
        }

        Divider()

        // --- Open tabs in this workspace (jump to build log / app log / sim) ---
        Text("WORKSPACE TABS")
            .font(.caption)
            .bold()
            .foregroundColor("#8E8E93")

        if workspaceCount == 0 {
            Text("No workspace open")
                .font(.caption)
                .foregroundColor("#8E8E93")
        } else {
            ForEach(workspaces) { ws in
                if ws.selected {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .foregroundColor("#FFD60A")
                            Text(ws.title).fontWeight(.semibold)
                        }
                        ForEach(ws.tabs) { tab in
                            HStack(spacing: 8) {
                                Image(systemName: tab.focused ? "largecircle.fill.circle" : "terminal")
                                    .foregroundColor(tab.focused ? "#34C759" : "#8E8E93")
                                Text(tab.title)
                                    .fontWeight(tab.focused ? .semibold : .regular)
                                Spacer()
                            }
                            .padding(4)
                            .onTapGesture {
                                cmux("surface.focus", surface_id: tab.id)
                            }
                        }
                    }
                }
            }
        }

        Divider()

        // --- Recent destinations strip (one-tap re-select) ---
        Text("RECENT")
            .font(.caption)
            .bold()
            .foregroundColor("#8E8E93")
        let recents = ["iPhone 16 Pro", "Aziz iPhone 15 Pro", "iPad Pro 13\""]
        ForEach(recents) { r in
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor("#8E8E93")
                Text(r).font(.caption)
                Spacer()
            }
            .padding(3)
            .onTapGesture {
                cmux("ios.destination.select", name: r)
            }
        }

        Spacer()
    }
    .padding(12)
}
