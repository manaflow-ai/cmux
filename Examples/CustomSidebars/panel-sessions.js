// panel-sessions: right-sidebar demo. Every session (terminal/browser tab)
// with live search and a scope toggle: just the selected workspace, or all
// workspaces. Click a row to jump to that session.
//   cp Examples/CustomSidebars/panel-sessions.js ~/.config/cmux/sidebars/
//   cmux right-sidebar set custom panel-sessions

const [query, setQuery] = signal("");
const [scopeAll, setScopeAll] = signal(false);

const matches = (text) => {
  const q = query().trim().toLowerCase();
  if (!q) return true;
  return String(text ?? "").toLowerCase().includes(q);
};

// One flat entry per session, carrying its workspace for labels and jumps.
const sessions = computed(() => {
  const all = data.workspaces() ?? [];
  const scoped = scopeAll() ? all : all.filter((w) => w.selected);
  const out = [];
  for (const w of scoped) {
    for (const t of w.tabs ?? []) {
      if (!matches(t.title) && !matches(w.title) && !matches(t.directory) && !matches(t.branch)) continue;
      out.push({
        key: w.id + ":" + t.id,
        wsId: w.id,
        wsTitle: w.title,
        surfaceId: t.surfaceId,
        title: t.title,
        focused: t.focused && w.selected,
        branch: t.branch,
        dirty: t.dirty,
        directory: t.directory,
        ports: t.ports ?? [],
      });
    }
  }
  return out;
});

function jump(s) {
  cmux("workspace.select", { workspace_id: s.wsId });
  if (s.surfaceId) cmux("surface.focus", { surface_id: s.surfaceId });
}

function scopeButton(label, all) {
  return Text(label)
    .font(11).weight("semibold")
    .paddingHorizontal(8).paddingVertical(3)
    .cornerRadius(6)
    .color(() => (scopeAll() === all ? "primary" : "tertiary"))
    .background(() => (scopeAll() === all ? "#7f7f7f3d" : null))
    .hoverBackground("#7f7f7f3d")
    .onTap(() => setScopeAll(all));
}

sidebar(() =>
  VStack({ spacing: 8 }, [
    HStack({ spacing: 6 }, [
      Text("Sessions").font(14).weight("semibold"),
      Spacer(),
      Text(() => String(sessions().length)).font(11).color("tertiary"),
    ]).paddingHorizontal(10),

    HStack({ spacing: 4 }, [
      scopeButton("This workspace", false),
      scopeButton("All", true),
      Spacer(),
    ]).paddingHorizontal(10),

    TextField("", {
      placeholder: "Search sessions",
      autofocus: false,
      onEdit: (t) => setQuery(t ?? ""),
      onSubmit: (t) => setQuery(t ?? ""),
    }).paddingHorizontal(10),

    ForEach(
      { items: sessions, key: (s) => s.key },
      (s) =>
        VStack({ spacing: 2 }, [
          HStack({ spacing: 6 }, [
            Circle({ size: 6 })
              .fill(() => (s().focused ? "#34C759" : "#7f7f7f66")),
            Text(() => s().title || "untitled")
              .font(12).lineLimit(1).truncation("tail")
              .color(() => (s().focused ? "primary" : "secondary")),
            Spacer(),
            Text(() => (s().ports.length ? ":" + s().ports.join(" :") : ""))
              .font(10).monospaced().color("tertiary"),
          ]),
          HStack({ spacing: 6 }, [
            Text(() => s().wsTitle).font(10).color("tertiary").lineLimit(1).truncation("tail"),
            Text(() => (s().branch ? "· " + s().branch + (s().dirty ? " ●" : "") : ""))
              .font(10).color("tertiary").lineLimit(1),
            Spacer(),
          ]).paddingLeading(12),
        ])
          .paddingHorizontal(10).paddingVertical(5)
          .cornerRadius(8)
          .hoverBackground("#7f7f7f24")
          .frame({ maxWidth: "infinity" })
          .onTap(() => jump(s()))
    ),

    Text(() => (sessions().length === 0 ? (query().trim() ? "No matches." : "No sessions.") : ""))
      .font(11).color("tertiary").paddingHorizontal(10),
    Spacer(),
  ]).paddingHorizontal(6),
  { surface: "glass" }
)
