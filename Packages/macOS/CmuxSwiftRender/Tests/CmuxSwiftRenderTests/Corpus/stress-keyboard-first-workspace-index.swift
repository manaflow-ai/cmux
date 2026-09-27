// Compact keyboard-first index.
// Dense LazyVStack of workspaces with monospaced enumeration numbers,
// branch in caption, selected row highlighted via background + overlay
// accent bar. Tap to select.

let bg = "#0d1117"
let panel = "#161b22"
let panelSel = "#1f6feb22"
let accent = "#58a6ff"
let accentDim = "#1f6feb"
let fg = "#e6edf3"
let dim = "#8b949e"
let faint = "#6e7681"
let good = "#3fb950"
let warn = "#d29922"
let bad = "#f85149"
let purple = "#bc8cff"

// jump labels: 1-9 then a..z for the overflow
let glyphs = ["1","2","3","4","5","6","7","8","9","a","b","c","d","e","f","g","h","i","j","k","l","m","n","o","p","q","r","s","t","u","v","w","x","y","z"]

func jump(_ i: Int) -> String {
    return i < glyphs.count ? glyphs[i] : "·"
}

func statusColor(_ s: String) -> String {
    if s == "open" { return good }
    if s == "merged" { return purple }
    if s == "closed" { return bad }
    if s == "draft" { return faint }
    return dim
}

// one mono key-cap glyph
func keycap(_ label: String, _ tint: String, _ active: Bool) -> some View {
    Text(label)
        .font(.system(size: 11, design: .monospaced))
        .bold()
        .foregroundColor(active ? "#0d1117" : tint)
        .frame(width: 18, height: 18, alignment: .center)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .foregroundColor(active ? tint : "#21262d")
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .foregroundColor("#00000000")
                        .border(active ? tint : "#30363d", width: 1)
                        .cornerRadius(4)
                }
        }
}

// tiny dot pill used for port / unread counts
func countPill(_ n: Int, _ tint: String, _ icon: String) -> some View {
    HStack(spacing: 2) {
        Image(systemName: icon)
            .font(.system(size: 8))
            .foregroundColor(tint)
        Text("\(n)")
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(tint)
            .bold()
    }
    .padding(2)
    .background {
        Capsule().foregroundColor(tint + "22")
    }
}

// branch + dirty caption for a workspace row
func branchCaption(_ w: SwiftValue) -> some View {
    HStack(spacing: 4) {
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 8))
            .foregroundColor(faint)
        Text(w.branch)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(dim)
            .lineLimit(1)
            .truncationMode(.tail)
        if w.dirty {
            Circle()
                .foregroundColor(warn)
                .frame(width: 5, height: 5)
        }
        if w.pr.number > 0 {
            Text("#\(w.pr.number)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(statusColor(w.pr.status))
                .bold()
        }
    }
}

// full dense workspace row
func row(_ i: Int, _ w: SwiftValue) -> some View {
    HStack(spacing: 8) {
        // index keycap
        keycap(jump(i), w.selected ? accent : faint, w.selected)

        // selected accent bar
        Rectangle()
            .foregroundColor(w.selected ? accent : "#00000000")
            .frame(width: 2, height: 30)
            .cornerRadius(1)

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if w.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundColor(warn)
                        .rotationEffect(.degrees(45))
                }
                Text(w.title)
                    .font(.system(size: 12))
                    .fontWeight(w.selected ? .semibold : .regular)
                    .foregroundColor(w.selected ? fg : "#c9d1d9")
                    .lineLimit(1)
                    .truncationMode(.tail)
                if w.remote.connected {
                    Image(systemName: "bolt.horizontal.fill")
                        .font(.system(size: 8))
                        .foregroundColor(good)
                        .help("remote: \(w.remote.target)")
                }
            }
            branchCaption(w)
        }

        Spacer()

        // right side: counts column
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 4) {
                if w.unread > 0 {
                    countPill(w.unread, bad, "envelope.badge.fill")
                }
                if w.portCount > 0 {
                    countPill(w.portCount, accent, "network")
                }
            }
            Text("\(w.tabCount)t")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(faint)
        }
    }
    .padding(7)
    .background {
        RoundedRectangle(cornerRadius: 7)
            .foregroundColor(w.selected ? panelSel : "#00000000")
    }
    .overlay(alignment: .topTrailing) {
        if w.progress.value > 0 && w.progress.value < 1 {
            Capsule()
                .foregroundColor(accentDim + "33")
                .frame(width: 30, height: 3)
                .overlay(alignment: .topTrailing) {
                    Capsule()
                        .foregroundColor(accent)
                        .frame(width: 30 * w.progress.value, height: 3)
                }
                .offset(x: -6, y: 4)
        }
    }
    .contextMenu {
        Button("Select") { cmux("workspace.select", workspace_id: w.id) }
        Button("Focus window") { cmux("window.focus") }
    }
    .onTapGesture { cmux("workspace.select", workspace_id: w.id) }
    .help("\(w.title) — \(w.directory)")
}

// ── ROOT ────────────────────────────────────────────────────────────
let pinned = workspaces.filter { $0.pinned }
let unreadWs = workspaces.filter { $0.unread > 0 }.count
let dirtyWs = workspaces.filter { $0.dirty }.count

ScrollView {
    VStack(alignment: .leading, spacing: 10) {

        // ── header strip ──────────────────────────────────────────
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "number.square.fill")
                    .font(.system(size: 13))
                    .foregroundColor(accent)
                Text("INDEX")
                    .font(.system(size: 11, design: .monospaced))
                    .bold()
                    .foregroundColor(fg)
                    .textCase(.uppercase)
                Spacer()
                Text(clock.time)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(dim)
            }

            // quick stat row, all derived from real keys
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    Text("\(workspaceCount)")
                        .font(.system(size: 11, design: .monospaced))
                        .bold()
                        .foregroundColor(fg)
                    Text("ws")
                        .font(.system(size: 9))
                        .foregroundColor(faint)
                }
                Divider().frame(height: 10)
                if unreadTotal > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "envelope.badge.fill")
                            .font(.system(size: 9))
                            .foregroundColor(bad)
                        Text("\(unreadTotal)")
                            .font(.system(size: 11, design: .monospaced))
                            .bold()
                            .foregroundColor(bad)
                    }
                }
                if dirtyWs > 0 {
                    HStack(spacing: 3) {
                        Circle().foregroundColor(warn).frame(width: 6, height: 6)
                        Text("\(dirtyWs) dirty")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(warn)
                    }
                }
                Spacer()
            }
            .padding(6)
            .background {
                RoundedRectangle(cornerRadius: 6).foregroundColor(panel)
            }
        }

        // ── pinned shortcut strip (horizontal) ────────────────────
        if pinned.count > 0 {
            Text("PINNED")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(faint)
                .textCase(.uppercase)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    for p in pinned {
                        HStack(spacing: 4) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8))
                                .foregroundColor(warn)
                            Text(p.title)
                                .font(.system(size: 10))
                                .foregroundColor(p.selected ? fg : dim)
                                .lineLimit(1)
                        }
                        .padding(5)
                        .background {
                            Capsule().foregroundColor(p.selected ? accentDim + "33" : "#21262d")
                        }
                        .onTapGesture { cmux("workspace.select", workspace_id: p.id) }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }

        Divider()

        // ── the dense enumerated index ────────────────────────────
        HStack(spacing: 6) {
            Text("WORKSPACES")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(faint)
                .textCase(.uppercase)
            Spacer()
            Text("⌘1–9 jump")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(faint)
        }

        LazyVStack(alignment: .leading, spacing: 3) {
            ForEach(Array(workspaces.enumerated()), id: \.offset) { i, w in
                row(i, w)

                // inline surface jump-list for the selected workspace
                if w.selected && w.tabCount > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(w.tabs.enumerated()), id: \.offset) { ti, t in
                            HStack(spacing: 6) {
                                Text("└")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(faint)
                                keycap(jump(ti), t.focused ? warn : faint, t.focused)
                                if t.focused {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 6))
                                        .foregroundColor(warn)
                                }
                                Text(t.title)
                                    .font(.system(size: 11))
                                    .foregroundColor(t.focused ? fg : dim)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if t.pinned {
                                    Image(systemName: "pin.fill")
                                        .font(.system(size: 7))
                                        .foregroundColor(faint)
                                }
                                Spacer()
                            }
                            .padding(3)
                            .onTapGesture { cmux("surface.focus", surface_id: t.id) }
                        }
                    }
                    .padding(4)
                    .background {
                        UnevenRoundedRectangle(cornerRadius: 6)
                            .foregroundColor("#0d111799")
                    }
                    .offset(x: 14)
                }
            }
        }

        // ── footer: selected workspace context ────────────────────
        if selectedTitle.count > 0 {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(accent)
                    Text(selectedTitle)
                        .font(.system(size: 11))
                        .bold()
                        .foregroundColor(fg)
                        .lineLimit(1)
                }
                let sel = workspaces.filter { $0.selected }
                if sel.count > 0 {
                    let s = sel[0]
                    if s.latestMessage.count > 0 {
                        Text(s.latestMessage)
                            .font(.system(size: 10))
                            .foregroundColor(dim)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if s.ports.count > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "network")
                                .font(.system(size: 8))
                                .foregroundColor(accent)
                            for port in s.ports.prefix(6) {
                                Text(":\(port)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(accent)
                                    .padding(2)
                                    .background {
                                        RoundedRectangle(cornerRadius: 3)
                                            .foregroundColor(accent + "1a")
                                    }
                            }
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8).foregroundColor(panel)
            }
        }
    }
    .padding(10)
}
.scrollIndicators(.hidden)
.background { Rectangle().foregroundColor(bg) }
.safeAreaInset(edge: .top) {
    Color("#0d1117").frame(height: 8)
}