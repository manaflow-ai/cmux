HSplitView {
    // ============== LEFT: NOTES popover for the active workspace ==============
    VStack(alignment: .leading, spacing: 10) {
        // Header with a notes glyph that would open the popover.
        HStack(spacing: 6) {
            Image(systemName: "note.text")
                .foregroundColor("#E5C07B")
            Text("NOTES")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor("#888888")
            Spacer()
            // Tapping the glyph should present the notes popover (see missingFeatures: popover).
            Button(action: { log("notes.popover.open") }) {
                Image(systemName: "rectangle.expand.vertical")
                    .foregroundColor("#888888")
            }
        }

        Text(selectedTitle)
            .font(.headline)
            .bold()

        // Per-workspace notes. The interpreter has no `notes` live data and no
        // mutable TextField, so I inline my own notes keyed by directory. In the
        // real feature these come from a `notes` snapshot field and a popover editor.
        let notesByDir = [
            "/Users/me/cmux": [
                "next: wire pbxproj test target for new file",
                "gotcha: macOS 26 CFURL normalization differs from 14/15",
                "blocked: waiting on dogfood approval before merge"
            ],
            "/Users/me/web": [
                "waiting on Vercel preview URL before reporting done",
                "Effect: map typed errors at route boundary"
            ],
            "/Users/me/ios": [
                "next: reload sim + best-effort iPhone, short tag (<=6 chars)"
            ]
        ]

        // I want the notes for whichever workspace is selected. Without a way to
        // find the selected workspace's directory ergonomically (no first(where:),
        // no optional chaining), I scan and bind it in the loop below.
        for w in workspaces {
            if w.selected {
                let lines = notesByDir[w.directory]
                if lines.isEmpty {
                    Text("No notes yet. Tap + to add one.")
                        .font(.caption)
                        .foregroundColor("#666666")
                } else {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "circle.fill")
                                .font(.caption)
                                .foregroundColor("#4078F2")
                            Text(line)
                                .font(.caption)
                                .foregroundColor("#D0D0D0")
                        }
                        .onTapGesture { log("note.focus: \(line)") }
                    }
                }
            }
        }

        Divider()

        // Tabs of the active workspace, tap to focus the surface.
        Text("TABS")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor("#888888")
        for w in workspaces {
            if w.selected {
                for t in w.tabs {
                    Button(action: { cmux("surface.focus", surface_id: t.id) }) {
                        HStack(spacing: 6) {
                            if t.focused {
                                Image(systemName: "largecircle.fill.circle")
                                    .foregroundColor("#98C379")
                            } else {
                                Image(systemName: "circle")
                                    .foregroundColor("#555555")
                            }
                            Text(t.title)
                                .font(.caption)
                                .foregroundColor(t.focused ? "#FFFFFF" : "#9AA0A6")
                        }
                    }
                }
            }
        }

        Spacer()

        // Add-note affordance. No TextField/popover yet, so it logs intent.
        Button(action: { log("note.add for \(selectedTitle)") }) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .foregroundColor("#4078F2")
                Text("Add note")
                    .font(.caption)
                    .foregroundColor("#4078F2")
            }
        }
    }
    .padding(12)

    // ============== RIGHT: searchable, project-grouped switcher ==============
    VStack(alignment: .leading, spacing: 8) {
        // Search row. The interpreter has no TextField / local mutable state, so
        // this is a tappable affordance that logs the intent. The real version is
        // a live TextField that filters `query` below.
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor("#888888")
            Text("Search workspaces…")
                .font(.caption)
                .foregroundColor("#666666")
            Spacer()
            Text("\(workspaceCount)")
                .font(.caption)
                .foregroundColor("#666666")
        }
        .padding(6)
        .onTapGesture { log("switcher.search.focus") }

        Divider()

        // Group by project root (the workspace `directory`). I want the leaf
        // folder name as the group label, but the interpreter has no string
        // split/last-path-component, so I group on the full directory string and
        // show it directly. ForEach over a derived set of roots would be ideal;
        // instead I list known roots and filter per group.
        let roots = [
            "/Users/me/cmux",
            "/Users/me/web",
            "/Users/me/ios"
        ]
        for root in roots {
            // Header per group with count.
            let inGroup = workspaces.filter { $0.directory == root }
            if !inGroup.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundColor("#61AFEF")
                    Text(root)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor("#ABB2BF")
                    Spacer()
                    Text("\(inGroup.count)")
                        .font(.caption)
                        .foregroundColor("#666666")
                }
                ForEach(inGroup) { w in
                    Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
                        HStack(spacing: 8) {
                            if w.selected {
                                Image(systemName: "chevron.right.circle.fill")
                                    .foregroundColor("#98C379")
                            } else {
                                Image(systemName: "circle")
                                    .foregroundColor("#3A3A3A")
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(w.title)
                                    .foregroundColor(w.selected ? "#FFFFFF" : "#9AA0A6")
                                    .fontWeight(w.selected ? .semibold : .regular)
                                Text("\(w.tabs.count) tabs")
                                    .font(.caption)
                                    .foregroundColor("#666666")
                            }
                            Spacer()
                        }
                        .padding(4)
                    }
                }
                Divider()
            }
        }

        // Catch-all for workspaces whose directory isn't a known root.
        let ungrouped = workspaces.filter { $0.directory != "/Users/me/cmux" && $0.directory != "/Users/me/web" && $0.directory != "/Users/me/ios" }
        if !ungrouped.isEmpty {
            Text("OTHER")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor("#888888")
            ForEach(ungrouped) { w in
                Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
                    HStack(spacing: 8) {
                        Image(systemName: "circle")
                            .foregroundColor("#3A3A3A")
                        Text(w.title)
                            .foregroundColor(w.selected ? "#FFFFFF" : "#9AA0A6")
                        Spacer()
                    }
                    .padding(4)
                }
            }
        }

        Spacer()
    }
    .padding(12)
}
