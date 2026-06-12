HSplitView {
    // LEFT: the manuscript — open markdown files (tabs) with live word counts
    VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 6) {
            Image(systemName: "doc.text").foregroundColor("#7AA2F7")
            Text("Writing Desk").font(.headline).bold()
            Spacer()
            Text("\(selectedTitle)").font(.caption).foregroundColor("#888888")
        }

        // Session word goal — total words across all open files vs a 2000-word target.
        // wordsTotal / wordGoal / sprintRemaining are NOT in the data context yet.
        let pct = wordsTotal * 100 / wordGoal
        HStack(spacing: 6) {
            Text("Words").font(.caption).bold()
            Spacer()
            if wordsTotal >= wordGoal {
                Text("\(wordsTotal) / \(wordGoal) ✓").font(.caption).foregroundColor("#9ECE6A").bold()
            } else {
                Text("\(wordsTotal) / \(wordGoal)  (\(pct)%)").font(.caption).foregroundColor("#E0AF68")
            }
        }

        // Writing-sprint timer with a 25-minute goal. Tapping toggles the sprint.
        HStack(spacing: 6) {
            Image(systemName: "timer").foregroundColor("#BB9AF7")
            if sprintActive {
                Text("Sprint \(sprintRemaining) left").font(.caption).bold().foregroundColor("#BB9AF7")
            } else {
                Text("Start 25m sprint").font(.caption).foregroundColor("#888888")
            }
        }
        .padding(4)
        .onTapGesture { cmux("writer.sprint.toggle", minutes: 25) }

        Divider()

        // Open files = the focused workspace's tabs, each row a markdown buffer.
        Text("Open files").font(.caption).bold().foregroundColor("#888888")
        for ws in workspaces {
            if ws.selected {
                for tab in ws.tabs {
                    Button(action: { cmux("surface.focus", surface_id: tab.id) }) {
                        HStack(spacing: 6) {
                            if tab.focused {
                                Image(systemName: "pencil.line").foregroundColor("#7AA2F7")
                            } else {
                                Image(systemName: "doc").foregroundColor("#555555")
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                if tab.dirty {
                                    Text("\(tab.title) •").bold()
                                } else {
                                    Text(tab.title)
                                }
                                // tab.words / tab.budget are richer per-buffer data, not present yet.
                                if tab.words > tab.budget {
                                    Text("\(tab.words)w  over by \(tab.words - tab.budget)").font(.caption).foregroundColor("#F7768E")
                                } else {
                                    Text("\(tab.words)w / \(tab.budget)").font(.caption).foregroundColor("#666666")
                                }
                            }
                            Spacer()
                        }
                        .padding(4)
                    }
                }
            }
        }

        Spacer()

        // Snippet actions for the file I'm in.
        HStack(spacing: 8) {
            Button("＋ Section") { cmux("writer.insert", snippet: "## ") }
                .font(.caption).foregroundColor("#7AA2F7")
            Button("Frontmatter") { cmux("writer.insert", snippet: "frontmatter") }
                .font(.caption).foregroundColor("#7AA2F7")
        }
        .padding(4)
    }
    .padding(8)

    // RIGHT: the publish lane
    VStack(alignment: .leading, spacing: 12) {
        Text("Publish").font(.headline).bold()

        // Big goal readout.
        let remaining = wordGoal - wordsTotal
        if wordsTotal >= wordGoal {
            Text("\(wordsTotal)").font(.title2).bold().foregroundColor("#9ECE6A")
            Text("goal reached").font(.caption).foregroundColor("#9ECE6A")
        } else {
            Text("\(wordsTotal)").font(.title2).bold().foregroundColor("#E0AF68")
            Text("\(remaining) words to goal").font(.caption).foregroundColor("#888888")
        }

        Divider()

        // Pre-publish checklist. dirtyCount / lintClean are richer git/lint state, not present yet.
        if dirtyCount > 0 {
            Text("\(dirtyCount) file(s) with unsaved or uncommitted changes").font(.caption).foregroundColor("#E0AF68")
        } else {
            Text("Working tree clean").font(.caption).foregroundColor("#9ECE6A")
        }

        Button(action: { cmux("writer.format") }) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                Text("Format + lint (prettier)")
            }.font(.caption).foregroundColor("#7AA2F7").padding(4)
        }

        Button(action: { cmux("writer.preview") }) {
            HStack(spacing: 6) {
                Image(systemName: "eye")
                Text("Live preview")
            }.font(.caption).foregroundColor("#7AA2F7").padding(4)
        }

        Button(action: { cmux("writer.commit", message: "docs: writing session") }) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal")
                Text("Commit draft")
            }.font(.caption).foregroundColor("#7AA2F7").padding(4)
        }

        Spacer()

        // The publish button — only meant to be hot when clean + at goal, but the interpreter
        // has no .disabled / conditional styling depth, so I gate the label text instead.
        if lintClean {
            Button(action: { cmux("writer.publish") }) {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill")
                    Text("Publish").bold()
                }.foregroundColor("#9ECE6A").padding(8)
            }
        } else {
            Button(action: { cmux("writer.format") }) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Fix lint before publishing")
                }.font(.caption).foregroundColor("#F7768E").padding(8)
            }
        }
    }
    .padding(8)
}
