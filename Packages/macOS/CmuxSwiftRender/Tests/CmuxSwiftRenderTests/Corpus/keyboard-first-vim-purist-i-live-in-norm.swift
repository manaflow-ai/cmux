let accent = "#7aa2f7"
let dim = "#565f89"
let fg = "#c0caf5"
let warn = "#e0af68"
let jumpKeys = ["a", "s", "d", "f", "g", "h", "j", "k", "l", "q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]

VStack(alignment: .leading, spacing: 10) {

    // ── Zone 1: modeline / status strip ──────────────────────────────
    HStack(spacing: 6) {
        Text(" NORMAL ")
            .font(.caption)
            .bold()
            .foregroundColor("#1a1b26")
            .padding(2)
        Text("⌘‹leader›")
            .font(.caption)
            .foregroundColor(dim)
        Spacer()
        Text("\(workspaceCount)w")
            .font(.caption)
            .foregroundColor(dim)
    }

    HStack(spacing: 6) {
        Text(":")
            .font(.caption)
            .foregroundColor(accent)
            .bold()
        Text(selectedTitle)
            .font(.caption)
            .foregroundColor(fg)
            .bold()
    }

    Divider()

    // ── Zone 2: workspace jump-list (vim buffer marks) ───────────────
    Text("BUFFERS")
        .font(.caption)
        .foregroundColor(dim)
        .fontWeight(.semibold)

    VStack(alignment: .leading, spacing: 3) {
        for i in 0..<workspaceCount {
            let w = workspaces[i]

            // workspace row: <jumpkey> <caret> <title>            <tabs>
            HStack(spacing: 6) {
                Text(i < jumpKeys.count ? jumpKeys[i] : "·")
                    .font(.caption)
                    .foregroundColor(accent)
                    .bold()
                if w.selected {
                    Text("▸")
                        .font(.caption)
                        .foregroundColor(accent)
                } else {
                    Text(" ")
                        .font(.caption)
                        .foregroundColor(dim)
                }
                if w.selected {
                    Text(w.title)
                        .font(.caption)
                        .foregroundColor(fg)
                        .bold()
                } else {
                    Text(w.title)
                        .font(.caption)
                        .foregroundColor(dim)
                }
                Spacer()
                Text("\(w.tabs.count)")
                    .font(.caption)
                    .foregroundColor(dim)
            }
            .onTapGesture { cmux("workspace.select", workspace_id: w.id) }

            // nested surface jump-rows for the selected workspace only
            if w.selected {
                for t in 0..<w.tabs.count {
                    let tab = w.tabs[t]
                    HStack(spacing: 6) {
                        Text("  ")
                            .font(.caption)
                        Text(jumpKeys[t % jumpKeys.count])
                            .font(.caption)
                            .foregroundColor(warn)
                        if tab.focused {
                            Text("●")
                                .font(.caption)
                                .foregroundColor(warn)
                        } else {
                            Text("○")
                                .font(.caption)
                                .foregroundColor(dim)
                        }
                        if tab.focused {
                            Text(tab.title)
                                .font(.caption)
                                .foregroundColor(fg)
                        } else {
                            Text(tab.title)
                                .font(.caption)
                                .foregroundColor(dim)
                        }
                    }
                    .onTapGesture { cmux("surface.focus", surface_id: tab.id) }
                }
            }
        }
    }

    Divider()

    // ── Zone 3: command legend / cheatsheet ──────────────────────────
    Text("CHORDS")
        .font(.caption)
        .foregroundColor(dim)
        .fontWeight(.semibold)

    HSplitView {
        VStack(alignment: .leading, spacing: 3) {
            for pair in [["⌘w", "next ws"], ["⌘b", "prev ws"], ["gt", "next tab"], ["gT", "prev tab"], ["⌘/", "search"]] {
                HStack(spacing: 8) {
                    Text(pair[0])
                        .font(.caption)
                        .foregroundColor(accent)
                        .bold()
                    Text(pair[1])
                        .font(.caption)
                        .foregroundColor(dim)
                }
            }
        }
        VStack(alignment: .leading, spacing: 3) {
            for pair in [["⌘x", "close"], ["⌘\\", "vsplit"], ["⌘-", "hsplit"], ["⌘p", "palette"], ["⌘1-9", "jump n"]] {
                HStack(spacing: 8) {
                    Text(pair[0])
                        .font(.caption)
                        .foregroundColor(accent)
                        .bold()
                    Text(pair[1])
                        .font(.caption)
                        .foregroundColor(dim)
                }
            }
        }
    }
}
.padding(10)
