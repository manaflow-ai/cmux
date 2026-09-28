VStack(alignment: .leading, spacing: 1) {
    ForEach(workspaces) { w in
        Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(w.selected ? "#4C9EEB" : "#00000000")
                    .frame(width: 2, height: 14)
                Text(w.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundColor(w.selected ? .primary : .secondary)
                Spacer()
                if w.unread > 0 {
                    Text("\(w.unread)").font(.caption2).foregroundColor(.red)
                }
            }
            .padding(4)
        }
    }
}
