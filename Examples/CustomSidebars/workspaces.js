// Dia-style workspace sidebar: groups, cross-group drag, full context menus.
//
// The whole sidebar is ONE flat drag surface: group headers and workspace
// rows live in a single Reorderable. Headers are `fixed` (not grabbable, but
// they shift to open gaps like any row), so a workspace can be dragged
// between groups, into a group, or out to the ungrouped area in one gesture.
// The drop resolves to (container group, reorder anchor) from the flat index
// and dispatches workspace.group.add/remove + workspace.reorder.
//
// Group collapse is optimistic (a local signal flips instantly) and syncs via
// workspace.group.collapse/expand so the built-in sidebar agrees.
//
// Install:  cp Examples/CustomSidebars/workspaces.js ~/.config/cmux/sidebars/
// Open:     cmux sidebar open workspaces

// --- optimistic collapse -----------------------------------------------------
const collapseOverride = new Map();
const [collapseTick, setCollapseTick] = signal(0);

function isCollapsed(g) {
  collapseTick();
  if (collapseOverride.has(g.id)) {
    const v = collapseOverride.get(g.id);
    if (v === g.collapsed) collapseOverride.delete(g.id); // host caught up
    else return v;
  }
  return g.collapsed;
}

function toggleCollapse(g) {
  const next = !isCollapsed(g);
  collapseOverride.set(g.id, next);
  setCollapseTick(collapseTick() + 1);
  cmux(next ? "workspace.group.collapse" : "workspace.group.expand", { group_id: g.id });
}

// --- data helpers ------------------------------------------------------------
const groupById = (id) => (data.groups() ?? []).find((g) => g.id === id);
const membersOf = (id) => (data.workspaces() ?? []).filter((w) => w.group === id);
// The anchor workspace IS the header (matching the built-in sidebar).
const memberRowsOf = (id) => {
  const g = groupById(id);
  return membersOf(id).filter((w) => !g || w.id !== g.anchorId);
};

// One flat entry list: a group renders (header + expanded member rows) at its
// first member's position; ungrouped workspaces are plain rows.
const flatEntries = computed(() => {
  const ws = data.workspaces() ?? [];
  const groups = new Map((data.groups() ?? []).map((g) => [g.id, g]));
  const out = [];
  const seen = new Set();
  for (const w of ws) {
    if (w.group && groups.has(w.group)) {
      if (seen.has(w.group)) continue;
      seen.add(w.group);
      const g = groups.get(w.group);
      out.push({ kind: "header", id: "h:" + g.id, groupId: g.id });
      if (!isCollapsed(g)) {
        for (const m of memberRowsOf(g.id)) {
          out.push({ kind: "ws", id: m.id, groupId: g.id });
        }
      }
    } else if (!w.group) {
      out.push({ kind: "ws", id: w.id, groupId: null });
    }
  }
  return out;
});

// --- drop resolution ---------------------------------------------------------
// `index` is the dragged row's slot in the flat list (headers included). The
// container is whatever sits directly above the slot; the reorder anchor is
// the next visible workspace row at or below it.
function handleMove(id, index) {
  const ws = data.workspaces() ?? [];
  const dragged = ws.find((w) => w.id === id);
  if (!dragged) return;
  const entries = flatEntries().filter((e) => e.id !== id);
  const prev = index > 0 ? entries[index - 1] : null;

  let container = prev ? prev.groupId : null;
  // Dropping right below a collapsed group's header means "after the whole
  // group", not "into it" (its rows are hidden), unless it already lives there.
  if (prev && prev.kind === "header") {
    const g = groupById(prev.groupId);
    if (g && isCollapsed(g) && dragged.group !== g.id) container = null;
  }

  const nextEntry = entries.slice(index).find((e) => e.kind === "ws");
  const nextWorkspace = nextEntry ? ws.find((w) => w.id === nextEntry.id) : null;

  if ((dragged.group ?? null) !== container) {
    if (container) {
      cmux("workspace.group.add", { group_id: container, workspace_id: id });
    } else {
      cmux("workspace.group.remove", { workspace_id: id });
    }
  }
  if (nextWorkspace) {
    const before = nextWorkspace.index;
    const target = dragged.index < before ? before - 1 : before;
    cmux("workspace.reorder", { workspace_id: id, index: target });
  } else {
    cmux("workspace.reorder", { workspace_id: id, index: ws.length - 1 });
  }
}

// --- rows ----------------------------------------------------------------------
function workspaceMenu(w) {
  const act = (action) => () =>
    cmux("workspace.action", { action, workspace_id: w().id });
  const groupItems = (data.groups() ?? []).map((g) =>
    Button(() => (groupById(g.id)?.name ?? ""), () =>
      cmux("workspace.group.add", { group_id: g.id, workspace_id: w().id })));
  return [
    Button(() => (w()?.pinned ? "Unpin" : "Pin"), () =>
      cmux("workspace.action", { action: w()?.pinned ? "unpin" : "pin", workspace_id: w().id })),
    Button(() => (w()?.unread > 0 ? "Mark as Read" : "Mark as Unread"), () =>
      cmux("workspace.action", { action: w()?.unread > 0 ? "mark_read" : "mark_unread", workspace_id: w().id })),
    Divider(),
    Menu("Move", [
      Button("Move Up", act("move_up")),
      Button("Move Down", act("move_down")),
      Button("Move to Top", act("move_top")),
    ]),
    Menu("Move to Group", groupItems),
    Button("Remove from Group", () => cmux("workspace.group.remove", { workspace_id: w().id })),
    Divider(),
    Button("Close Others", act("close_others")).destructive(),
    Button("Close", () => cmux("workspace.close", { workspace_id: w().id })).destructive(),
  ];
}

function workspaceRow(w, entry) {
  return HStack({ spacing: 8 }, [
    Text(() => w()?.title ?? "")
      .font(13)
      .lineLimit(1)
      .truncation("tail")
      .color(() => (w()?.selected ? "primary" : "secondary")),
    Spacer(),
    Text(() => (w()?.unread > 0 ? String(w().unread) : ""))
      .font("caption2").bold().color("white")
      .paddingHorizontal(5).paddingVertical(1)
      .background(() => (w()?.unread > 0 ? "#E4573D" : null))
      .cornerRadius(7),
  ])
    .paddingLeading(() => (entry().groupId ? 22 : 10))
    .paddingTrailing(10)
    .paddingVertical(6)
    .cornerRadius(8)
    .background(() => (w()?.selected ? "#7f7f7f3d" : null))
    .hoverBackground(() => (w()?.selected ? "#7f7f7f3d" : "#7f7f7f24"))
    .frame({ maxWidth: "infinity" })
    .onTap(() => cmux("workspace.select", { workspace_id: w().id }))
    .contextMenu(workspaceMenu(w));
}

function groupHeader(groupId) {
  const g = () => groupById(groupId) ?? { id: groupId, name: "", collapsed: false, pinned: false };
  const anchor = () => (data.workspaces() ?? []).find((w) => w.id === g().anchorId);
  const groupAct = (action) => () =>
    cmux("workspace.group.action", { group_id: groupId, action });
  return HStack({ spacing: 6 }, [
    // The chevron toggles collapse; clicking anywhere else selects the
    // group's anchor workspace (built-in sidebar behavior). Chevron only,
    // no folder icon.
    Image(() => (isCollapsed(g()) ? "chevron.right" : "chevron.down"))
      .font(10).weight("semibold").color("tertiary")
      .frame({ width: 14 })
      .paddingVertical(4)
      .onTap(() => toggleCollapse(g())),
    Text(() => g().name).font(12).weight("semibold").lineLimit(1).truncation("tail")
      .color(() => (anchor()?.selected ? "primary" : "secondary")),
    Spacer(),
    Text(() => String(membersOf(groupId).length))
      .font("caption2").color("tertiary").monospaced(),
  ])
    .paddingLeading(8)
    .paddingTrailing(10)
    .paddingVertical(5)
    .cornerRadius(8)
    .background(() => (anchor()?.selected ? "#7f7f7f3d" : null))
    .hoverBackground(() => (anchor()?.selected ? "#7f7f7f3d" : "#7f7f7f1c"))
    .frame({ maxWidth: "infinity" })
    .fixed()
    .onTap(() => {
      const a = anchor();
      if (a) cmux("workspace.select", { workspace_id: a.id });
    })
    .contextMenu([
      Button(() => (isCollapsed(g()) ? "Expand" : "Collapse"), () => toggleCollapse(g())),
      Button(() => (g().pinned ? "Unpin Group" : "Pin Group"), () =>
        cmux("workspace.group.action", { group_id: groupId, action: g().pinned ? "unpin" : "pin" })),
      Divider(),
      Button("Ungroup", groupAct("ungroup")),
      Button("Delete Group", groupAct("delete")).destructive(),
    ]);
}

// --- root ------------------------------------------------------------------------
sidebar(() =>
  Reorderable(
    {
      items: flatEntries,
      key: (e) => e.id,
      spacing: 2,
      onMove: handleMove,
    },
    (e, key) => {
      const entry = e(); // kind and ids are stable per key
      if (entry.kind === "header") {
        return groupHeader(entry.groupId);
      }
      const w = () => (data.workspaces() ?? []).find((x) => x.id === key);
      return workspaceRow(w, e);
    }
  )
)
