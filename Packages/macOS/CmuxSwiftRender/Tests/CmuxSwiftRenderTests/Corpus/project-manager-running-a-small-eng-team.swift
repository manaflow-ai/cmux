VStack(spacing: 10) {
    // ---- Summary / header bar ----
    HStack(spacing: 6) {
        Image(systemName: "rectangle.split.3x1")
            .foregroundColor("#7C8CF8")
        Text("Sprint Board")
            .font(.headline)
            .bold()
        Spacer()
        Text("\(workspaceCount) tasks")
            .font(.caption)
            .foregroundColor("#8A8F98")
    }
    .padding(8)

    Text("Now: \(selectedTitle)")
        .font(.caption)
        .foregroundColor("#A0A0A8")
        .padding(6)

    Divider()

    // ---- Lane derivations ----
    // Convention: title prefix encodes lane.
    //   "[ ] Ship login  · due Mon"   -> To Do
    //   "[~] Refactor API · due Wed"  -> Doing
    //   "[x] Fix crash    · done"     -> Done
    let todo  = workspaces.filter { $0.title.hasPrefix("[ ]") }
    let doing = workspaces.filter { $0.title.hasPrefix("[~]") }
    let done  = workspaces.filter { $0.title.hasPrefix("[x]") }

    let doingOverLimit = doing.count > 3   // WIP limit = 3

    // ---- Three lanes ----
    HStack(alignment: .top, spacing: 8) {

        // === TO DO ===
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "circle")
                    .foregroundColor("#8A8F98")
                Text("To Do")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(todo.count)")
                    .font(.caption)
                    .bold()
                    .foregroundColor("#8A8F98")
            }
            Divider()
            if todo.isEmpty {
                Text("Empty")
                    .font(.caption)
                    .foregroundColor("#5A5F68")
                    .padding(4)
            }
            ForEach(todo) { task in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "square")
                            .foregroundColor("#8A8F98")
                        Text(task.title)
                            .font(.caption)
                            .foregroundColor(task.selected ? "#FFFFFF" : "#C8CCD4")
                    }
                    Text(dueLine(task))
                        .font(.caption)
                        .foregroundColor("#7A7F88")
                }
                .padding(6)
                .onTapGesture {
                    cmux(workspace.select, workspace_id: task.id)
                    log("focus todo \(task.title)")
                }
            }
        }

        Divider()

        // === DOING ===
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundColor("#F2C94C")
                Text("Doing")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(doing.count)")
                    .font(.caption)
                    .bold()
                    .foregroundColor(doingOverLimit ? "#EB5757" : "#F2C94C")
            }
            if doingOverLimit {
                Text("Over WIP limit (3)")
                    .font(.caption)
                    .foregroundColor("#EB5757")
            }
            Divider()
            ForEach(doing) { task in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        // attention dot: a focused tab means work is live
                        let live = task.tabs.filter { $0.focused }
                        Image(systemName: live.isEmpty ? "arrow.triangle.2.circlepath" : "dot.radiowaves.left.and.right")
                            .foregroundColor(live.isEmpty ? "#F2C94C" : "#27AE60")
                        Text(task.title)
                            .font(.caption)
                            .bold()
                            .foregroundColor(task.selected ? "#FFFFFF" : "#E0E4EC")
                    }
                    HStack(spacing: 4) {
                        Text(dueLine(task))
                            .font(.caption)
                            .foregroundColor(isOverdue(task) ? "#EB5757" : "#7A7F88")
                        Spacer()
                        Text("\(task.tabs.count) tabs")
                            .font(.caption)
                            .foregroundColor("#5A5F68")
                    }
                }
                .padding(6)
                .onTapGesture {
                    cmux(workspace.select, workspace_id: task.id)
                    log("jump into \(task.title)")
                }
            }
        }

        Divider()

        // === DONE ===
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor("#27AE60")
                Text("Done")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(done.count)")
                    .font(.caption)
                    .bold()
                    .foregroundColor("#27AE60")
            }
            Divider()
            ForEach(done) { task in
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .foregroundColor("#27AE60")
                    Text(task.title)
                        .font(.caption)
                        .foregroundColor("#7A7F88")
                }
                .padding(6)
                .onTapGesture {
                    cmux(workspace.select, workspace_id: task.id)
                }
            }
        }
    }

    Spacer()

    Divider()
    HStack(spacing: 8) {
        Button("Refresh") { log("manual refresh") }
            .font(.caption)
        Spacer()
        Text("\(done.count)/\(workspaceCount) done")
            .font(.caption)
            .foregroundColor("#8A8F98")
    }
    .padding(8)
}
