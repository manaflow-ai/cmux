HSplitView {
    VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .foregroundColor("#7C3AED")
            Text("Triage Cockpit")
                .font(.headline)
                .bold()
            Spacer()
            Text("\(workspaceCount)")
                .font(.caption)
                .foregroundColor("#9CA3AF")
        }
        .padding(4)

        Text("Reviewing: \(selectedTitle)")
            .font(.caption)
            .foregroundColor("#9CA3AF")
            .padding(4)

        Divider()

        Text("PR QUEUE")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor("#6B7280")
            .padding(4)

        ForEach(workspaces) { ws in
            HStack(spacing: 8) {
                Image(systemName: ws.selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(ws.selected ? "#22C55E" : "#4B5563")
                VStack(alignment: .leading, spacing: 2) {
                    Text(ws.title)
                        .font(.caption)
                        .fontWeight(ws.selected ? .semibold : .regular)
                        .foregroundColor(ws.selected ? "#F9FAFB" : "#D1D5DB")
                    Text("\(ws.tabs.count) tabs")
                        .font(.caption)
                        .foregroundColor("#6B7280")
                }
                Spacer()
                Button("merge") {
                    log("merge requested for \(ws.title)")
                    cmux("pr.merge", workspace_id: ws.id)
                }
                .font(.caption)
                .foregroundColor("#22C55E")
            }
            .padding(6)
            .onTapGesture {
                cmux("workspace.select", workspace_id: ws.id)
            }
        }

        Spacer()

        Divider()
        HStack(spacing: 10) {
            Button(action: { cmux("issue.refresh") }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("Sync").font(.caption)
                }
                .foregroundColor("#60A5FA")
            }
            Spacer()
            Button("Inbox Zero") {
                log("jump to oldest untriaged")
                cmux("issue.openOldest")
            }
            .font(.caption)
            .foregroundColor("#F59E0B")
        }
        .padding(4)
    }
    .padding(8)

    VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.split.3x1")
                .foregroundColor("#7C3AED")
            Text("Surfaces")
                .font(.headline)
                .bold()
            Spacer()
        }
        .padding(4)

        Text(selectedTitle)
            .font(.caption)
            .foregroundColor("#9CA3AF")
            .padding(4)

        Divider()

        ForEach(workspaces) { ws in
            if ws.selected {
                ForEach(ws.tabs) { tab in
                    HStack(spacing: 8) {
                        Image(systemName: tab.focused ? "square.fill" : "square")
                            .foregroundColor(tab.focused ? "#7C3AED" : "#4B5563")
                        Text(tab.title)
                            .font(.caption)
                            .fontWeight(tab.focused ? .semibold : .regular)
                            .foregroundColor(tab.focused ? "#F9FAFB" : "#D1D5DB")
                        Spacer()
                    }
                    .padding(6)
                    .onTapGesture {
                        cmux("surface.focus", surface_id: tab.id)
                    }
                }
            }
        }

        Spacer()
    }
    .padding(8)
}
