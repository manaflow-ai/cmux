// ---- helpers -----------------------------------------------------------

func prColor(_ status: String) -> String {
    if status == "merged" { return "#a371f7" }
    if status == "approved" { return "#3fb950" }
    if status == "changes_requested" { return "#f85149" }
    if status == "draft" { return "#6e7681" }
    if status == "review_required" { return "#d29922" }
    return "#58a6ff"
}

func prGlyph(_ status: String) -> String {
    if status == "merged" { return "arrow.triangle.merge" }
    if status == "approved" { return "checkmark.seal.fill" }
    if status == "changes_requested" { return "exclamationmark.triangle.fill" }
    if status == "draft" { return "pencil.circle" }
    if status == "review_required" { return "eye.circle.fill" }
    return "circle.dashed"
}

func statusRank(_ status: String) -> Int {
    if status == "changes_requested" { return 0 }
    if status == "review_required" { return 1 }
    if status == "approved" { return 2 }
    if status == "draft" { return 3 }
    if status == "merged" { return 4 }
    return 5
}

func statusLabel(_ status: String) -> String {
    if status == "changes_requested" { return "CHANGES" }
    if status == "review_required" { return "REVIEW" }
    if status == "approved" { return "APPROVED" }
    if status == "draft" { return "DRAFT" }
    if status == "merged" { return "MERGED" }
    return status
}

func sevWord(_ rank: Int) -> String {
    if rank == 0 { return "Blocking" }
    if rank == 1 { return "Needs you" }
    if rank == 2 { return "Ready" }
    if rank == 3 { return "In progress" }
    return "Done"
}

// status-color spark cell used inside overlays
func dot(_ hex: String, _ d: Double) -> some View {
    Circle()
        .foregroundColor(hex)
        .frame(width: d, height: d)
        .shadow(radius: 3, x: 0, y: 0, color: hex)
}

// ---- derived data ------------------------------------------------------

let reviewable = workspaces
    .filter { $0.pr != nil }
    .sorted { statusRank($0.pr.status) < statusRank($1.pr.status) }

let total = reviewable.count
let blocking = reviewable.filter { $0.pr.status == "changes_requested" }.count
let waiting = reviewable.filter { $0.pr.status == "review_required" }.count
let ready = reviewable.filter { $0.pr.status == "approved" }.count
let merged = reviewable.filter { $0.pr.status == "merged" }.count
let staleCount = reviewable.filter { $0.pr.stale }.count
let actionable = blocking + waiting
let doneFrac = total > 0 ? Double(merged + ready) / Double(total) : 0.0

// ---- root --------------------------------------------------------------

ScrollView {
    VStack(alignment: .leading, spacing: 14) {

        // ===== command header ==========================================
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .foregroundColor("#161b22")
                        .frame(width: 44, height: 44)
                        .overlay(alignment: .center) {
                            Image(systemName: "arrow.triangle.pull")
                                .imageScale(.large)
                                .foregroundStyle(.hierarchical)
                                .foregroundColor("#58a6ff")
                        }
                        .overlay(alignment: .topTrailing) {
                            Capsule()
                                .foregroundColor(actionable > 0 ? "#f85149" : "#3fb950")
                                .frame(width: actionable > 9 ? 22 : 17, height: 17)
                                .overlay(alignment: .center) {
                                    Text("\(actionable)")
                                        .font(.system(size: 10, design: .rounded))
                                        .bold()
                                        .foregroundColor("#ffffff")
                                }
                                .offset(x: 6, y: -6)
                        }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review Queue")
                        .font(.title)
                        .bold()
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .imageScale(.large)
                            .foregroundColor(.secondary)
                        Text("\(clock.time) · \(total) open PRs")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospaced()
                    }
                }
                Spacer()
            }

            // progress of "moving through" the queue
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Cleared")
                        .font(.caption)
                        .textCase(.uppercase)
                        .fontWeight(.semibold)
                        .foregroundColor(.tertiary)
                    Spacer()
                    Text(doneFrac.formatted(.percent))
                        .font(.caption)
                        .monospaced()
                        .foregroundColor("#3fb950")
                }
                ProgressView(value: doneFrac, total: 1.0)
                    .tint("#3fb950")
            }
        }
        .padding(12)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .foregroundColor("#0d1117")
                RoundedRectangle(cornerRadius: 14)
                    .foregroundColor(actionable > 0 ? "#f85149" : "#3fb950")
                    .opacity(0.08)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 3) {
                if staleCount > 0 {
                    dot("#d29922", 6)
                }
                dot(actionable > 0 ? "#f85149" : "#3fb950", 6)
            }
            .padding(10)
        }

        // ===== status tiles grid =======================================
        Grid {
            GridRow {
                ForEach([["changes_requested", "\(blocking)"], ["review_required", "\(waiting)"]], id: \.offset) { i, cell in
                    let st = cell[0]
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: prGlyph(st))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundColor(prColor(st))
                            Spacer()
                            Text(cell[1])
                                .font(.system(size: 22, design: .rounded))
                                .bold()
                                .foregroundColor(prColor(st))
                        }
                        Text(statusLabel(st))
                            .font(.caption)
                            .textCase(.uppercase)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background("#161b22")
                    .cornerRadius(10)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .foregroundColor(prColor(st))
                            .frame(width: 3)
                            .padding(4)
                    }
                }
            }
            GridRow {
                ForEach([["approved", "\(ready)"], ["merged", "\(merged)"]], id: \.offset) { i, cell in
                    let st = cell[0]
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: prGlyph(st))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundColor(prColor(st))
                            Spacer()
                            Text(cell[1])
                                .font(.system(size: 22, design: .rounded))
                                .bold()
                                .foregroundColor(prColor(st))
                        }
                        Text(statusLabel(st))
                            .font(.caption)
                            .textCase(.uppercase)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background("#161b22")
                    .cornerRadius(10)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .foregroundColor(prColor(st))
                            .frame(width: 3)
                            .padding(4)
                    }
                }
            }
        }

        // mini distribution bar across all statuses
        if total > 0 {
            HStack(spacing: 2) {
                ForEach(Array(reviewable.enumerated()), id: \.offset) { i, ws in
                    Rectangle()
                        .foregroundColor(prColor(ws.pr.status))
                        .frame(maxWidth: .infinity)
                        .frame(height: 6)
                        .opacity(ws.pr.stale ? 0.4 : 1.0)
                }
            }
            .clipShape(Capsule())
            .help("\(total) PRs · \(staleCount) stale")
        }

        Divider()

        // ===== the queue ================================================
        if total == 0 {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .imageScale(.large)
                    .scaleEffect(2.0)
                    .foregroundStyle(.hierarchical)
                    .foregroundColor("#3fb950")
                    .padding(.bottom, 6)
                Text("Inbox zero")
                    .font(.title)
                    .bold()
                Text("No open PRs in your workspaces.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        } else {
            HStack {
                Text("Sorted by status")
                    .font(.caption)
                    .textCase(.uppercase)
                    .fontWeight(.semibold)
                    .foregroundColor(.tertiary)
                Spacer()
                if staleCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "hourglass")
                            .imageScale(.large)
                        Text("\(staleCount) stale")
                    }
                    .font(.caption)
                    .foregroundColor("#d29922")
                }
            }

            LazyVStack(spacing: 9) {
                ForEach(Array(reviewable.enumerated()), id: \.offset) { idx, ws in
                    let pr = ws.pr
                    let c = prColor(pr.status)
                    let rank = statusRank(pr.status)

                    // ---- card ------------------------------------------
                    VStack(alignment: .leading, spacing: 8) {

                        // top line: PR number + status pill + menu
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("#\(pr.number)")
                                        .font(.system(size: 15, design: .monospaced))
                                        .bold()
                                        .foregroundColor(c)
                                    if ws.selected {
                                        Image(systemName: "location.fill")
                                            .imageScale(.large)
                                            .foregroundColor("#58a6ff")
                                            .help("Current workspace")
                                    }
                                    if ws.pinned {
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

                            // status pill
                            HStack(spacing: 4) {
                                Image(systemName: prGlyph(pr.status))
                                    .imageScale(.large)
                                    .symbolRenderingMode(.hierarchical)
                                Text(statusLabel(pr.status))
                                    .font(.system(size: 10, design: .rounded))
                                    .bold()
                            }
                            .foregroundColor(c)
                            .padding(5)
                            .background {
                                Capsule().foregroundColor(c).opacity(0.15)
                            }
                            .overlay(alignment: .center) {
                                Capsule().border(.gray, width: 0).opacity(0)
                            }

                            // actions menu
                            Menu("") {
                                Button("Open PR #\(pr.number)") { cmux("openURL", param: pr.url) }
                                Button("Focus workspace") { cmux("selectWorkspace", param: ws.id) }
                                Button("Approve") { cmux("prApprove", param: pr.number) }
                                Button("Request changes") { cmux("prRequestChanges", param: pr.number) }
                                Button("Refresh PR") { cmux("prRefresh", param: pr.number) }
                                if pr.status == "approved" {
                                    Button("Merge") { cmux("prMerge", param: pr.number) }
                                }
                            }
                        }

                        // branch + dirty + ports row
                        HStack(spacing: 8) {
                            if ws.branch != nil {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .imageScale(.large)
                                        .foregroundColor(.secondary)
                                    Text(ws.branch)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                            if ws.dirty {
                                Circle()
                                    .foregroundColor("#d29922")
                                    .frame(width: 6, height: 6)
                                    .help("Uncommitted changes")
                            }
                            Spacer()
                            if ws.portCount > 0 {
                                HStack(spacing: 3) {
                                    Image(systemName: "bolt.horizontal.fill")
                                        .imageScale(.large)
                                    Text("\(ws.portCount)")
                                }
                                .font(.system(size: 10, design: .rounded))
                                .foregroundColor("#58a6ff")
                            }
                            if ws.unread > 0 {
                                HStack(spacing: 3) {
                                    Image(systemName: "envelope.badge.fill")
                                        .imageScale(.large)
                                    Text("\(ws.unread)")
                                }
                                .font(.system(size: 10, design: .rounded))
                                .foregroundColor("#f85149")
                            }
                        }

                        // optional progress bar (agent working in workspace)
                        if ws.progress != nil {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(ws.progress.label)
                                        .font(.system(size: 10))
                                        .foregroundColor(.tertiary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(ws.progress.value.formatted(.percent))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.tertiary)
                                }
                                ProgressView(value: ws.progress.value, total: 1.0)
                                    .tint(c)
                            }
                        }
                    }
                    .padding(11)
                    // whole-card body redacts when stale
                    .redacted(reason: pr.stale ? .placeholder : nil)
                    .background {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .foregroundColor("#0d1117")
                            UnevenRoundedRectangle(topLeading: 12, bottomLeading: 12, bottomTrailing: 0, topTrailing: 0)
                                .foregroundColor(c)
                                .opacity(0.10)
                                .frame(width: 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .overlay(alignment: .leading) {
                        // status accent rail
                        UnevenRoundedRectangle(topLeading: 12, bottomLeading: 12, bottomTrailing: 0, topTrailing: 0)
                            .foregroundColor(c)
                            .frame(width: 4)
                    }
                    .overlay(alignment: .topTrailing) {
                        // severity ribbon for actionable PRs
                        if rank <= 1 && !pr.stale {
                            Text(sevWord(rank))
                                .font(.system(size: 8, design: .rounded))
                                .bold()
                                .textCase(.uppercase)
                                .foregroundColor("#ffffff")
                                .padding(3)
                                .background {
                                    Capsule().foregroundColor(c)
                                }
                                .offset(x: -8, y: -5)
                                .shadow(radius: 4, x: 0, y: 2, color: c)
                        }
                    }
                    .overlay(alignment: .center) {
                        // stale veil with badge
                        if pr.stale {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .foregroundColor("#000000")
                                    .opacity(0.18)
                                HStack(spacing: 5) {
                                    Image(systemName: "hourglass.circle.fill")
                                        .imageScale(.large)
                                        .symbolRenderingMode(.hierarchical)
                                    Text("STALE")
                                        .font(.system(size: 11, design: .rounded))
                                        .bold()
                                }
                                .foregroundColor("#d29922")
                                .padding(6)
                                .background {
                                    Capsule().foregroundColor("#161b22").opacity(0.92)
                                }
                            }
                        }
                    }
                    .shadow(radius: rank <= 1 ? 6 : 2, x: 0, y: 2, color: rank <= 1 ? c : "#000000")
                    .contextMenu {
                        Button("Open PR #\(pr.number)") { cmux("openURL", param: pr.url) }
                        Button("Focus workspace") { cmux("selectWorkspace", param: ws.id) }
                        Button("Refresh") { cmux("prRefresh", param: pr.number) }
                    }
                    .onTapGesture { cmux("selectWorkspace", param: ws.id) }
                    .help("\(sevWord(rank)) · \(ws.title)")
                }
            }
        }

        Divider()

        // ===== footer summary strip ====================================
        ViewThatFits {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "tray.full.fill")
                        .imageScale(.large)
                        .foregroundColor(.secondary)
                    Text("\(total) queued")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    cmux("prRefreshAll", param: total)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh all")
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                }
                .disabled(total == 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("\(total) queued")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button {
                    cmux("prRefreshAll", param: total)
                } label: {
                    Text("Refresh all")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
            }
        }
    }
    .padding(12)
}
.scrollIndicators(.hidden)