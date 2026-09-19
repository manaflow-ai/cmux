VStack(alignment: .leading, spacing: 8) {
  Text("My Sidebar")
    .font(.system(size: 13))
    .fontWeight(.semibold)
  Divider()
  ForEach(workspaces) { workspace in
    Button(action: { cmux("workspace.select", workspace_id: workspace.id) }) {
      Text(workspace.title)
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }
  Spacer()
}
.padding(8)
