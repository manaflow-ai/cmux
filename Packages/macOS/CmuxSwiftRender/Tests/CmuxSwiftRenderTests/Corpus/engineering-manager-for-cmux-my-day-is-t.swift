HSplitView {
    // LEFT: Review queue grouped by what needs a decision
    VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 6) {
            Image(systemName: "checklist")
                .foregroundColor("#5E9EFF")
            Text("Review Queue")
                .font(.headline)
                .bold()
            Spacer()
            Text("\(reviewQueue.count)")
                .font(.caption)
                .foregroundColor("#8A8A8E")
        }

        // Refresh + open my GitHub review dashboard
        Button(action: { cmux("review.refresh") }) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                Text("Refresh")
                    .font(.caption)
            }
            .foregroundColor("#8A8A8E")
        }

        Divider()

        // CI RED — highest priority, fix before anything else
        if redCount > 0 {
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundColor("#FF5C5C")
                Text("CI failing (\(redCount))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor("#FF5C5C")
            }
            ForEach(reviewQueue) { pr in
                if pr.ciState == "red" {
                    Button(action: { cmux("workspace.select", workspace_id: pr.workspaceId) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("#\(pr.number)")
                                    .font(.caption)
                                    .foregroundColor("#FF5C5C")
                                    .bold()
                                Text(pr.title)
                                    .font(.caption)
                            }
                            HStack(spacing: 6) {
                                Image(systemName: "person.crop.circle")
                                    .foregroundColor("#8A8A8E")
                                Text("\(pr.author) · \(pr.failingCheck)")
                                    .font(.caption)
                                    .foregroundColor("#8A8A8E")
                            }
                        }
                        .padding(6)
                    }
                }
            }
        }

        // WAITING ON ME — I'm the blocker
        if reviewCount > 0 {
            HStack(spacing: 6) {
                Image(systemName: "eye.fill")
                    .foregroundColor("#FFB23E")
                Text("Waiting on my review (\(reviewCount))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor("#FFB23E")
            }
            ForEach(reviewQueue) { pr in
                if pr.needsMyReview && pr.ciState != "red" {
                    Button(action: { cmux("pr.open", url: pr.url) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("#\(pr.number)")
                                    .font(.caption)
                                    .foregroundColor("#FFB23E")
                                    .bold()
                                Text(pr.title)
                                    .font(.caption)
                                Spacer()
                                Text("\(pr.waitingHours)h")
                                    .font(.caption)
                                    .foregroundColor("#8A8A8E")
                            }
                            Text("\(pr.author) · +\(pr.additions)/-\(pr.deletions)")
                                .font(.caption)
                                .foregroundColor("#8A8A8E")
                        }
                        .padding(6)
                    }
                }
            }
        }

        // MERGEABLE — green, approved, just hit the button
        if mergeableCount > 0 {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor("#46D17F")
                Text("Ready to merge (\(mergeableCount))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor("#46D17F")
            }
            ForEach(reviewQueue) { pr in
                if pr.mergeable {
                    HStack(spacing: 6) {
                        Text("#\(pr.number) \(pr.title)")
                            .font(.caption)
                        Spacer()
                        Button(action: { cmux("pr.merge", url: pr.url) }) {
                            Text("Merge")
                                .font(.caption)
                                .bold()
                                .foregroundColor("#46D17F")
                                .padding(4)
                        }
                    }
                    .padding(6)
                }
            }
        }

        if reviewQueue.isEmpty {
            Text("Queue empty. Ship something.")
                .font(.caption)
                .foregroundColor("#8A8A8E")
                .padding(8)
        }
    }
    .padding(4)

    // RIGHT: my workspaces + where agents are running
    VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.3.group")
                .foregroundColor("#5E9EFF")
            Text("Workspaces")
                .font(.headline)
                .bold()
            Spacer()
            Text("\(workspaceCount)")
                .font(.caption)
                .foregroundColor("#8A8A8E")
        }
        Divider()
        ForEach(workspaces) { w in
            VStack(alignment: .leading, spacing: 3) {
                Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
                    HStack(spacing: 6) {
                        if w.selected {
                            Image(systemName: "folder.fill")
                                .foregroundColor("#5E9EFF")
                        } else {
                            Image(systemName: "folder")
                                .foregroundColor("#8A8A8E")
                        }
                        Text(w.title)
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Text("\(w.tabs.count)")
                            .font(.caption)
                            .foregroundColor("#8A8A8E")
                    }
                }
                // Show the tabs of the active workspace so I can jump to the agent pane
                if w.selected {
                    ForEach(w.tabs) { t in
                        Button(action: { cmux("surface.focus", surface_id: t.id) }) {
                            HStack(spacing: 6) {
                                if t.focused {
                                    Image(systemName: "doc.text.fill")
                                        .foregroundColor("#5E9EFF")
                                } else {
                                    Image(systemName: "doc.text")
                                        .foregroundColor("#8A8A8E")
                                }
                                Text(t.title)
                                    .font(.caption)
                            }
                            .padding(2)
                        }
                    }
                }
            }
            .padding(4)
        }
    }
    .padding(4)
}
