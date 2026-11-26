HSplitView {
    // LEFT: triage column (alerts + incident + runbooks)
    VStack(spacing: 10) {

        // --- Incident / paging banner ---
        if incident.active {
            VStack(spacing: 4) {
                HStack {
                    Image(systemName: "bell.badge.fill")
                        .foregroundColor("#FF3B30")
                    Text("SEV\(incident.sev) ACTIVE")
                        .font(.headline).bold()
                        .foregroundColor("#FF3B30")
                    Spacer()
                    Text("\(incident.ageMin)m")
                        .font(.caption)
                        .foregroundColor("#FF9F0A")
                }
                Text(incident.title)
                    .font(.caption)
                HStack {
                    Button("Ack") { cmux("incident.ack", incident_id: incident.id) }
                        .padding(4)
                        .foregroundColor("#0A84FF")
                    Button("Bridge") { cmux("link.open", url: incident.bridgeUrl) }
                        .padding(4)
                        .foregroundColor("#0A84FF")
                    Spacer()
                    Text("\(incident.responders) on call")
                        .font(.caption)
                        .foregroundColor("#8E8E93")
                }
            }
            .padding(8)
        } else {
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor("#30D158")
                Text("No active incident")
                    .font(.caption)
                    .foregroundColor("#8E8E93")
                Spacer()
            }
            .padding(8)
        }

        Divider()

        // --- Active alerts, severity-sorted by the host ---
        HStack {
            Text("ALERTS")
                .font(.caption).fontWeight(.semibold)
                .foregroundColor("#8E8E93")
            Spacer()
            Text("\(alerts.count)")
                .font(.caption)
                .foregroundColor("#8E8E93")
        }
        .padding(4)

        if alerts.isEmpty {
            Text("All clear")
                .font(.caption)
                .foregroundColor("#30D158")
                .padding(6)
        }

        ForEach(alerts) { a in
            VStack(spacing: 3) {
                HStack {
                    // severity dot, color injected per-alert by host
                    Image(systemName: "circle.fill")
                        .font(.caption)
                        .foregroundColor(a.color)
                    Text(a.severity)
                        .font(.caption).bold()
                        .foregroundColor(a.color)
                    Spacer()
                    Text("\(a.ageMin)m")
                        .font(.caption)
                        .foregroundColor("#8E8E93")
                }
                Text(a.name)
                    .font(.caption).bold()
                HStack {
                    Image(systemName: "server.rack")
                        .font(.caption)
                        .foregroundColor("#8E8E93")
                    Text(a.service)
                        .font(.caption)
                        .foregroundColor("#8E8E93")
                    Spacer()
                }
                HStack {
                    Button("Ack") { cmux("alert.ack", alert_id: a.id) }
                        .font(.caption)
                        .padding(3)
                        .foregroundColor("#0A84FF")
                    Button("Runbook") { cmux("link.open", url: a.runbookUrl) }
                        .font(.caption)
                        .padding(3)
                        .foregroundColor("#0A84FF")
                    Button("Logs") { cmux("sre.tail", service: a.service) }
                        .font(.caption)
                        .padding(3)
                        .foregroundColor("#0A84FF")
                    Spacer()
                }
            }
            .padding(6)
            .onTapGesture { cmux("sre.tail", service: a.service) }
            Divider()
        }

        // --- Runbook quick launch ---
        Text("RUNBOOKS")
            .font(.caption).fontWeight(.semibold)
            .foregroundColor("#8E8E93")
            .padding(4)
        ForEach(runbooks) { r in
            HStack {
                Image(systemName: "book.closed.fill")
                    .font(.caption)
                    .foregroundColor("#5E5CE6")
                Text(r.title)
                    .font(.caption)
                Spacer()
            }
            .padding(4)
            .onTapGesture { cmux("link.open", url: r.url) }
        }
    }
    .padding(8)

    // RIGHT: live log tail of the selected service
    VStack(spacing: 4) {
        HStack {
            Image(systemName: "text.alignleft")
                .foregroundColor("#0A84FF")
            Text("LOGS · \(tailService)")
                .font(.caption).fontWeight(.semibold)
            Spacer()
            Button(action: { cmux("sre.tail.terminal", service: tailService) }) {
                HStack {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.caption)
                    Text("to term")
                        .font(.caption)
                }
                .foregroundColor("#0A84FF")
            }
        }
        .padding(6)
        Divider()
        if logLines.isEmpty {
            Text("waiting for log stream…")
                .font(.caption)
                .foregroundColor("#8E8E93")
                .padding(8)
        }
        ForEach(logLines) { line in
            HStack {
                Text(line.level)
                    .font(.caption).bold()
                    .foregroundColor(line.color)
                Text(line.text)
                    .font(.caption)
                    .foregroundColor("#D1D1D6")
                Spacer()
            }
            .padding(2)
        }
    }
    .padding(8)
}
