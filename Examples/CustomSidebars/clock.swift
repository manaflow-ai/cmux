VStack(alignment: .leading, spacing: 12) {
    VStack(alignment: .leading, spacing: 2) {
        Text(clock.time)
            .font(.system(size: 30, weight: .bold, design: .monospaced))
        Text("\(workspaceCount) workspaces · \(unreadTotal) unread")
            .font(.caption)
            .foregroundColor(.secondary)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background("#7f7f7f22")
    .cornerRadius(10)

    Text("WORKSPACES").font(.caption2).foregroundColor(.secondary)
    ForEach(workspaces) { w in
        Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
            HStack(spacing: 8) {
                Text(w.selected ? "●" : "○")
                    .font(.caption2)
                    .foregroundColor(w.selected ? "#4C9EEB" : .secondary)
                Text(w.title).font(.system(size: 13)).lineLimit(1)
                Spacer()
                if w.unread > 0 {
                    Text("\(w.unread)").font(.caption2).foregroundColor(.orange)
                }
            }
            .padding(6)
        }
    }
}
