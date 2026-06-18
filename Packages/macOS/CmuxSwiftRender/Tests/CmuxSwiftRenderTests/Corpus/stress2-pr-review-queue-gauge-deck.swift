// ---- value-func helpers (switch + return) ------------------------------

func prColor(_ status: String) -> String {
    switch status {
    case "changes_requested": return "#f85149"
    case "review_required":   return "#d29922"
    case "approved":          return "#3fb950"
    case "draft":             return "#6e7681"
    case "merged":            return "#a371f7"
    default:                  return "#58a6ff"
    }
}

func prGlyph(_ status: String) -> String {
    switch status {
    case "changes_requested": return "exclamationmark.triangle.fill"
    case "review_required":   return "eye.circle.fill"
    case "approved":          return "checkmark.seal.fill"
    case "draft":             return "pencil.circle"
    case "merged":            return "arrow.triangle.merge"
    default:                  return "circle.dashed"
    }
}

func prTitle(_ status: String) -> String {
    switch status {
    case "changes_requested": return "Changes requested"
    case "review_required":   return "Review required"
    case "approved":          return "Approved"
    case "draft":             return "Draft"
    case "merged":            return "Merged"
    default:                  return status
    }
}

// queue priority: blocking + review-needed come first, merged sinks
func prRank(_ status: String) -> Int {
    switch status {
    case "changes_requested": return 0
    case "review_required":   return 1
    case "approved":          return 2
    case "draft":             return 3
    case "merged":            return 4
    default:                  return 5
    }
}

// "weight" each open PR adds to the reviewer's load
func prWeight(_ status: String, _ stale: Bool) -> Double {
    let base = switch status {
        case "changes_requested": 3.0
        case "review_required":   2.0
        case "approved":          0.5
        case "draft":             0.25
        default:                  0.0
    }
    return stale ? base + 1.0 : base
}

func loadWord(_ frac: Double) -> String {
    if frac >= 0.85 { return "Overloaded" }
    if frac >= 0.55 { return "Heavy" }
    if frac >= 0.25 { return "Steady" }
    if frac > 0.0   { return "Light" }
    return "Clear"
}

func loadColor(_ frac: Double) -> String {
    if frac >= 0.85 { return "#f85149" }
    if frac >= 0.55 { return "#d29922" }
    if frac >= 0.25 { return "#58a6ff" }
    return "#3fb950"
}

// reusable status-color spark dot
func spark(_ hex: String, _ d: Double) -> some View {
    Circle()
        .foregroundColor(hex)
        .frame(width: d, height: d)
        .shadow(color: hex, radius: 3, x: 0, y: 0)
}

// ---- derived data ------------------------------------------------------

let reviewable = workspaces
    .filter { $0.pr != nil }
    .sorted { prRank($0.pr.status) < prRank($1.pr.status) }

let total = reviewable.count
let blocking = reviewable.filter { $0.pr.status == "changes_requested" }.count
let waiting  = reviewable.filter { $0.pr.status == "review_required" }.count
let staleCount = reviewable.filter { $0.pr.stale }.count
let actionable = blocking + waiting

// review-load gauge: sum of per-PR weights, normalized against a "full plate"
let loadRaw = reviewable.reduce(0.0) { $0 + prWeight($1.pr.status, $1.pr.stale) }
let loadCap = max(loadRaw, 12.0)
let loadFrac = loadCap > 0 ? loadRaw / loadCap : 0.0

// ---- root --------------------------------------------------------------

ScrollView {
    VStack(alignment: .leading, spacing: 14) {

        // ===== header: review-load Gauge ===============================
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                // circular load gauge
                ZStack {
                    Circle()
                        .stroke("#21262d", lineWidth: 6)
                        .frame(width: 64, height: 64)
                    Circle()
                        .trim(from: 0.0, to: loadFrac)
                        .stroke(loadColor(loadFrac), lineWidth: 6)
                        .frame(width: 64, height: 64)
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(Int(loadRaw))")
                            .font(.system(size: 20, design: .rounded))
                            .bold()
                            .monospacedDigit()
                            .foregroundColor(loadColor(loadFrac))
                        Text("load")
                            .font(.system(size: 8))
                            .textCase(.uppercase)
                            .foregroundColor(.tertiary)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Review Queue")
                        .font(.title)
                        .bold()
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.badge.gearshape")
                            .imageScale(.large)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(loadColor(loadFrac))
                        Text(loadWord(loadFrac))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(loadColor(loadFrac))
                        Text("· \(clock.time)")
                            .font(.caption)
                            .monospaced()
                            .foregroundColor(.tertiary)
                    }
                    // native Gauge mirroring the same load fraction
                    Gauge(value: loadFrac, total: 1.0) {
                        Text("LOAD")
                            .font(.system(size: 8))
                            .foregroundColor(.tertiary)
                    }
                    .tint(loadColor(loadFrac))
                }
                Spacer()
            }
            // status spark strip
            if total > 0 {
                HStack(spacing: 3) {
                    ForEach(Array(reviewable.enumerated()), id: \.offset) { i, ws in
                        spark(prColor(ws.pr.status), ws.pr.stale ? 5 : 7)
                            .opacity(ws.pr.stale ? 0.45 : 1.0)
                    }
                    Spacer()
                    Text("\(actionable) need you")
                        .font(.system(size: 10, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundColor(actionable > 0 ? "#f85149" : "#3fb950")
                }
            }
        }
        .padding(13)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .foregroundColor("#0d1117")
                LinearGradient(
                    colors: [loadColor(loadFrac), "#0d1117"],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(0.10)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .overlay(alignment: .topTrailing) {
            if staleCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "hourglass")
                        .imageScale(.large)
                    Text("\(staleCount)")
                        .monospacedDigit()
                }
                .font(.system(size: 10, design: .rounded))
                .bold()
                .foregroundColor("#d29922")
                .padding(5)
                .background { Capsule().foregroundColor("#161b22").opacity(0.9) }
                .padding(9)
            }
        }

        Divider()

        // ===== the queue ================================================
        if total == 0 {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .imageScale(.large)
                    .scaleEffect(2.0)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor("#3fb950")
                    .padding(.bottom, 6)
                Text("Queue clear")
                    .font(.title)
                    .bold()
                Text("No open PRs across your workspaces.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(28)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(Array(reviewable.enumerated()), id: \.offset) { idx, w in
                    // ---- the requested conditional rich card ----------
                    if let pr = w.pr {
                        let c = prColor(pr.status)
                        let rank = prRank(pr.status)
                        let hot = rank <= 1 && !pr.stale

                        VStack(alignment: .leading, spacing: 9) {

                            // top line: number / label / status / menu
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text("#\(pr.number)")
                                            .font(.system(size: 15, design: .monospaced))
                                            .bold()
                                            .foregroundColor(c)
                                        if w.selected {
                                            Image(systemName: "location.fill")
                                                .imageScale(.large)
                                                .foregroundColor("#58a6ff")
                                                .help("Current workspace")
                                        }
                                        if w.pinned {
                                            Image(systemName: "pin.fill")
                                                .imageScale(.large)
                                                .foregroundColor("#d29922")
                                        }
                                    }
                                    Text(pr.label)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .lineLimit(2)
                                        .truncationMode(.tail)
                                }
                                Spacer()
                                // status pill (switch-derived color + glyph + title)
                                HStack(spacing: 4) {
                                    Image(systemName: prGlyph(pr.status))
                                        .imageScale(.large)
                                        .symbolRenderingMode(.hierarchical)
                                    Text(prTitle(pr.status))
                                        .font(.system(size: 9, design: .rounded))
                                        .bold()
                                        .textCase(.uppercase)
                                        .fixedSize()
                                }
                                .foregroundColor(c)
                                .padding(5)
                                .background { Capsule().foregroundColor(c).opacity(0.15) }

                                // per-row actions Menu
                                Menu {
                                    Button("Open #\(pr.number)") { cmux("pr.open", url: pr.url) }
                                    Button("Focus workspace") { cmux("workspace.select", workspace_id: w.id) }
                                    Divider()
                                    switch pr.status {
                                    case "review_required":
                                        Button("Approve") { cmux("pr.approve", number: pr.number) }
                                        Button("Request changes") { cmux("pr.requestChanges", number: pr.number) }
                                    case "changes_requested":
                                        Button("Re-review") { cmux("pr.review", number: pr.number) }
                                    case "approved":
                                        Button("Merge") { cmux("pr.merge", number: pr.number) }
                                    default:
                                        Button("View checks") { cmux("pr.checks", number: pr.number) }
                                    }
                                    if pr.stale {
                                        Button("Refresh (stale)") { cmux("pr.refresh", number: pr.number) }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .imageScale(.large)
                                        .foregroundColor(.secondary)
                                }
                            }

                            // meta row: branch / dirty / ports / unread
                            HStack(spacing: 8) {
                                if w.branch != nil {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.triangle.branch")
                                            .imageScale(.large)
                                            .foregroundColor(.secondary)
                                        Text(w.branch)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                if w.dirty {
                                    Circle()
                                        .foregroundColor("#d29922")
                                        .frame(width: 6, height: 6)
                                        .help("Uncommitted changes")
                                }
                                Spacer()
                                if w.portCount > 0 {
                                    HStack(spacing: 3) {
                                        Image(systemName: "bolt.horizontal.fill")
                                            .imageScale(.large)
                                        Text("\(w.portCount)")
                                            .monospacedDigit()
                                    }
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundColor("#58a6ff")
                                }
                                if w.unread > 0 {
                                    HStack(spacing: 3) {
                                        Image(systemName: "envelope.badge.fill")
                                            .imageScale(.large)
                                        Text("\(w.unread)")
                                            .monospacedDigit()
                                    }
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundColor("#f85149")
                                }
                            }
                        }
                        .padding(11)
                        // stale PRs render as redacted placeholders
                        .redacted(reason: pr.stale ? .placeholder : nil)
                        .background {
                            RoundedRectangle(cornerRadius: 12)
                                .foregroundColor("#0d1117")
                        }
                        .overlay(alignment: .leading) {
                            // status accent rail
                            UnevenRoundedRectangle(
                                topLeading: 12, bottomLeading: 12,
                                bottomTrailing: 0, topTrailing: 0
                            )
                            .foregroundColor(c)
                            .frame(width: 4)
                        }
                        .overlay(alignment: .topTrailing) {
                            if hot {
                                Text(rank == 0 ? "BLOCKING" : "NEEDS YOU")
                                    .font(.system(size: 8, design: .rounded))
                                    .bold()
                                    .foregroundColor("#ffffff")
                                    .padding(3)
                                    .background { Capsule().foregroundColor(c) }
                                    .offset(x: -8, y: -5)
                                    .shadow(color: c, radius: 4, x: 0, y: 2)
                            }
                        }
                        .overlay(alignment: .center) {
                            // stale veil sits ABOVE the redacted body
                            if pr.stale {
                                HStack(spacing: 5) {
                                    Image(systemName: "hourglass.circle.fill")
                                        .imageScale(.large)
                                        .symbolRenderingMode(.hierarchical)
                                    Text("STALE · TAP TO REFRESH")
                                        .font(.system(size: 10, design: .rounded))
                                        .bold()
                                }
                                .foregroundColor("#d29922")
                                .padding(6)
                                .background { Capsule().foregroundColor("#161b22").opacity(0.92) }
                            }
                        }
                        .shadow(
                            color: hot ? c : "#000000",
                            radius: hot ? 6 : 2, x: 0, y: 2
                        )
                        .contextMenu {
                            Button("Open #\(pr.number)") { cmux("pr.open", url: pr.url) }
                            Button("Focus workspace") { cmux("workspace.select", workspace_id: w.id) }
                            Button("Refresh") { cmux("pr.refresh", number: pr.number) }
                        }
                        .onTapGesture {
                            cmux(pr.stale ? "pr.refresh" : "workspace.select", workspace_id: w.id)
                        }
                        .help("\(prTitle(pr.status)) · \(w.title)")
                    } else {
                        EmptyView()
                    }
                }
            }
        }

        Divider()

        // ===== footer ===================================================
        ViewThatFits {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "tray.full.fill")
                        .imageScale(.large)
                        .foregroundColor(.secondary)
                    Text("\(total) in queue · \(staleCount) stale")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    cmux("pr.refreshAll", count: total)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh all")
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                }
                .disabled(total == 0)
                .keyboardShortcut(.return)
            }
            HStack {
                Text("\(total) in queue")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Refresh") { cmux("pr.refreshAll", count: total) }
                    .font(.caption)
                    .fontWeight(.semibold)
            }
        }
    }
    .padding(12)
}
.scrollIndicators(.hidden)