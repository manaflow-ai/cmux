func workspaceIcon(_ w) -> String {
  if w.pinned { return "pin.fill" }
  if w.remote != nil && w.remote.connected == true { return "network" }
  if hasPR(w) { return "arrow.triangle.pull" }
  return "folder.fill"
}

func workspaceTint(_ w) -> String {
  if w.selected { return "#0A84FF" }
  if w.unread > 0 { return "#FF9F0A" }
  if w.dirty == true { return "#34C759" }
  return "#8E8E93"
}

func statusText(_ w) -> String {
  if hasPR(w) { return w.pr.label }
  if hasBranch(w) && w.dirty == true { return "\(w.branch) modified" }
  if hasBranch(w) { return w.branch }
  if w.portCount > 0 { return "\(w.portCount) ports" }
  return "\(w.tabCount) tabs"
}

func hasBranch(_ w) -> Bool {
  return w.branch != nil && w.branch != ""
}

func hasPR(_ w) -> Bool {
  return w.pr != nil && w.pr.label != nil && w.pr.label != ""
}

func hasProgress(_ w) -> Bool {
  return w.progress != nil && w.progress.value != nil
}

func hasLatestMessage(_ w) -> Bool {
  return w.latestMessage != nil && w.latestMessage != ""
}

func tabIcon(_ t) -> String {
  if t.pinned { return "pin.fill" }
  if t.ports.count > 0 { return "network" }
  return t.focused ? "doc.text.fill" : "doc.text"
}

func tabSubtitle(_ t) -> String {
  if t.branch != nil && t.branch != "" && t.dirty == true { return "\(t.branch) modified" }
  if t.branch != nil && t.branch != "" { return t.branch }
  if t.directory != nil && t.directory != "" { return t.directory }
  return "Terminal tab"
}

func finderRow(_ w) -> some View {
  Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
    HStack(spacing: 7) {
      Image(systemName: workspaceIcon(w))
        .font(.system(size: 12))
        .foregroundColor(workspaceTint(w))
        .frame(width: 15)
      VStack(alignment: .leading, spacing: 1) {
        Text(w.title)
          .font(.system(size: 12))
          .fontWeight(w.selected ? .semibold : .regular)
          .foregroundColor(w.selected ? .primary : .secondary)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(statusText(w))
          .font(.system(size: 9))
          .foregroundColor(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      if w.unread > 0 {
        Text("\(w.unread)")
          .font(.system(size: 9, design: .monospaced))
          .fontWeight(.semibold)
          .foregroundColor(.white)
          .padding(4)
          .background { Capsule().foregroundColor("#FF3B30") }
      }
    }
    .padding(6)
    .background { RoundedRectangle(cornerRadius: 7).foregroundColor(w.selected ? "#0A84FF" : "#000000").opacity(w.selected ? 0.18 : 0.0) }
  }
}

func tabRow(_ tab) -> some View {
  Button(action: { cmux("surface.focus", surface_id: tab.id) }) {
    HStack(spacing: 8) {
      Image(systemName: tabIcon(tab))
        .foregroundColor(tab.focused ? "#0A84FF" : .secondary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(tab.title)
          .font(.system(size: 12))
          .fontWeight(tab.focused ? .semibold : .regular)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(tabSubtitle(tab))
          .font(.system(size: 9))
          .foregroundColor(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
    }
    .padding(6)
    .background { RoundedRectangle(cornerRadius: 7).foregroundColor(tab.focused ? "#0A84FF" : "#000000").opacity(tab.focused ? 0.12 : 0.0) }
  }
}

func workspaceDetails(_ w) -> some View {
  VStack(alignment: .leading, spacing: 8) {
    HStack(alignment: .top, spacing: 9) {
      ZStack {
        RoundedRectangle(cornerRadius: 8).foregroundColor(workspaceTint(w)).opacity(0.16)
        Image(systemName: workspaceIcon(w)).foregroundColor(workspaceTint(w))
      }
      .frame(width: 36, height: 36)
      VStack(alignment: .leading, spacing: 3) {
        Text(w.title).font(.system(size: 14)).fontWeight(.semibold).lineLimit(2)
        Text(w.directory).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
      }
      Spacer()
    }

    HStack(spacing: 6) {
      Label("\(w.tabCount)", systemImage: "rectangle.on.rectangle").font(.system(size: 10)).foregroundColor(.secondary)
      if w.portCount > 0 {
        Label("\(w.portCount)", systemImage: "network").font(.system(size: 10)).foregroundColor("#34C759")
      }
      if hasPR(w) {
        Label(w.pr.label, systemImage: "arrow.triangle.pull").font(.system(size: 10)).foregroundColor("#0A84FF")
      }
      if w.unread > 0 {
        Label("\(w.unread)", systemImage: "bell.fill").font(.system(size: 10)).foregroundColor("#FF9F0A")
      }
      Spacer()
    }

    if hasProgress(w) {
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(w.progress.label).font(.system(size: 10)).foregroundColor(.secondary)
          Spacer()
        }
        ProgressView(value: w.progress.value, total: 1.0).tint("#0A84FF")
      }
    }

    if hasLatestMessage(w) {
      Text(w.latestMessage)
        .font(.system(size: 10))
        .foregroundColor(.secondary)
        .lineLimit(2)
        .padding(7)
        .background { RoundedRectangle(cornerRadius: 7).foregroundColor("#8E8E93").opacity(0.12) }
    }
  }
  .padding(8)
  .background { RoundedRectangle(cornerRadius: 9).foregroundColor("#8E8E93").opacity(0.10) }
}

HSplitView {
  VStack(alignment: .leading, spacing: 6) {
    HStack {
      Text("Cmux").font(.system(size: 13)).fontWeight(.semibold)
      Spacer()
      Text("\(workspaceCount)").font(.system(size: 10, design: .monospaced)).foregroundColor(.tertiary)
    }
    .padding(6)

    Text("Favorites")
      .font(.system(size: 10))
      .fontWeight(.semibold)
      .textCase(.uppercase)
      .foregroundColor(.tertiary)
      .padding(4)

    Reorderable(workspaces.prefix(30), move: "workspace.reorder") { w in
      finderRow(w)
    }

    Spacer()
  }
  .padding(4)

  VStack(alignment: .leading, spacing: 7) {
    HStack {
      Text(selectedTitle).font(.system(size: 13)).fontWeight(.semibold).lineLimit(1)
      Spacer()
      Text(clock.time).font(.system(size: 10, design: .monospaced)).foregroundColor(.tertiary)
    }
    .padding(6)

    ForEach(workspaces.filter { $0.selected }.prefix(1)) { selected in
      workspaceDetails(selected)

      HStack {
        Text("Tabs")
          .font(.system(size: 10))
          .fontWeight(.semibold)
          .textCase(.uppercase)
          .foregroundColor(.tertiary)
        Spacer()
        Text("\(selected.tabCount)")
          .font(.system(size: 10, design: .monospaced))
          .foregroundColor(.tertiary)
      }
      .padding(4)

      if selected.tabs.isEmpty {
        VStack(spacing: 6) {
          Image(systemName: "rectangle.badge.plus").font(.system(size: 20)).foregroundColor(.tertiary)
          Text("No tabs in this workspace").font(.system(size: 11)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
      } else {
        ForEach(selected.tabs.prefix(24)) { tab in
          tabRow(tab)
        }
      }
    }

    Spacer()
  }
  .padding(4)
}
