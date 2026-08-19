// Dia-style workspace sidebar with groups and full right-click menus.
//
// Sections mirror the real sidebar: a group renders (header + members) at the
// position of its first member; ungrouped workspaces render flat. Group
// collapse is optimistic (a local signal flips instantly) and syncs to the
// app through workspace.group.collapse/expand, so the built-in sidebar and
// this one agree. Every row and header has a context menu wired to the same
// socket verbs the app's own menus use.
//
// Install:  cp Examples/CustomSidebars/workspaces.js ~/.config/cmux/sidebars/
// Open:     cmux sidebar open workspaces

// --- optimistic collapse -------------------------------------------------
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

// --- display sections ------------------------------------------------------
// A group renders at its first member's position; consecutive ungrouped
// workspaces coalesce into a "run" that gets its own Reorderable (nesting a
// draggable row inside another draggable list would make the gestures fight,
// so group BLOCKS move via their context menu, not by drag).
const sections = computed(() => {
  const ws = data.workspaces() ?? [];
  const groups = new Map((data.groups() ?? []).map((g) => [g.id, g]));
  const out = [];
  const seen = new Set();
  let inRun = false;
  for (const w of ws) {
    if (w.group && groups.has(w.group)) {
      inRun = false;
      if (seen.has(w.group)) continue;
      seen.add(w.group);
      out.push({ kind: "group", id: "g:" + w.group, groupId: w.group });
    } else if (!inRun) {
      inRun = true;
      out.push({ kind: "run", id: "r:" + w.id, firstId: w.id });
    }
  }
  return out;
});

// The maximal consecutive ungrouped block containing `firstId`.
const runMembers = (firstId) => {
  const ws = data.workspaces() ?? [];
  const start = ws.findIndex((w) => w.id === firstId);
  if (start < 0) return [];
  let lo = start;
  while (lo > 0 && !ws[lo - 1].group) lo -= 1;
  let hi = start;
  while (hi + 1 < ws.length && !ws[hi + 1].group) hi += 1;
  return ws.slice(lo, hi + 1);
};

const groupById = (id) => (data.groups() ?? []).find((g) => g.id === id);
const membersOf = (id) => (data.workspaces() ?? []).filter((w) => w.group === id);

// --- rows ------------------------------------------------------------------
function workspaceMenu(w) {
  const act = (action) => () =>
    cmux("workspace.action", { action, workspace_id: w().id });
  return [
    Button(() => (w().pinned ? "Unpin" : "Pin"), () =>
      cmux("workspace.action", { action: w().pinned ? "unpin" : "pin", workspace_id: w().id })),
    Button(() => (w().unread > 0 ? "Mark as Read" : "Mark as Unread"), () =>
      cmux("workspace.action", { action: w().unread > 0 ? "mark_read" : "mark_unread", workspace_id: w().id })),
    Divider(),
    Menu("Move", [
      Button("Move Up", act("move_up")),
      Button("Move Down", act("move_down")),
      Button("Move to Top", act("move_top")),
      Divider(),
      Button("Move to New Window", () => cmux("workspace.move_to_window", { workspace_id: w().id })),
    ]),
    Button("Clear Color", act("clear_color")),
    Divider(),
    Button("Close Others", act("close_others")).destructive(),
    Button("Close", () => cmux("workspace.close", { workspace_id: w().id })).destructive(),
  ];
}

function workspaceRow(w, indented) {
  return HStack({ spacing: 8 }, [
    Text(() => w().title)
      .font(13)
      .lineLimit(1)
      .truncation("tail")
      .color(() => (w().selected ? "primary" : "secondary")),
    Spacer(),
    Text(() => (w().unread > 0 ? String(w().unread) : ""))
      .font("caption2").bold().color("white")
      .paddingHorizontal(5).paddingVertical(1)
      .background(() => (w().unread > 0 ? "#E4573D" : null))
      .cornerRadius(7),
  ])
    .paddingLeading(indented ? 24 : 10)
    .paddingTrailing(10)
    .paddingVertical(6)
    .cornerRadius(8)
    .background(() => (w().selected ? "#7f7f7f3d" : null))
    .hoverBackground(() => (w().selected ? "#7f7f7f3d" : "#7f7f7f24"))
    .frame({ maxWidth: "infinity" })
    .onTap(() => cmux("workspace.select", { workspace_id: w().id }))
    .contextMenu(workspaceMenu(w));
}

function memberList(groupId) {
  return Reorderable(
    {
      items: () => {
        const g = groupById(groupId);
        return g && isCollapsed(g) ? [] : membersOf(groupId);
      },
      key: (w) => w.id,
      spacing: 2,
      onMove: (id, index) => {
        // Local slot -> global tabs index: the member currently at that slot.
        const members = membersOf(groupId);
        const target = members[Math.min(index, members.length - 1)];
        if (target) cmux("workspace.reorder", { workspace_id: id, index: target.index });
      },
    },
    (w) => workspaceRow(w, true)
  );
}

function groupHeader(groupId) {
  const g = () => groupById(groupId) ?? { id: groupId, name: "", collapsed: false, pinned: false };
  const groupAct = (action) => () =>
    cmux("workspace.group.action", { group_id: groupId, action });
  return HStack({ spacing: 6 }, [
    Image(() => (isCollapsed(g()) ? "chevron.right" : "chevron.down"))
      .font(10).color("tertiary"),
    Image(() => g().icon ?? "folder.fill")
      .font(11)
      .color(() => g().color ?? "secondary"),
    Text(() => g().name).font(12).weight("semibold").lineLimit(1).truncation("tail"),
    Spacer(),
    Text(() => String(membersOf(groupId).length)).font("caption2").color("tertiary").monospaced(),
  ])
    .paddingHorizontal(10)
    .paddingVertical(5)
    .cornerRadius(8)
    .hoverBackground("#7f7f7f1c")
    .frame({ maxWidth: "infinity" })
    .onTap(() => toggleCollapse(g()))
    .contextMenu([
      Button(() => (isCollapsed(g()) ? "Expand" : "Collapse"), () => toggleCollapse(g())),
      Button(() => (g().pinned ? "Unpin Group" : "Pin Group"), () =>
        cmux("workspace.group.action", { group_id: groupId, action: g().pinned ? "unpin" : "pin" })),
      Divider(),
      Button("Ungroup", groupAct("ungroup")),
      Button("Delete Group", groupAct("delete")).destructive(),
    ]);
}

function runList(firstId) {
  return Reorderable(
    {
      items: () => runMembers(firstId),
      key: (w) => w.id,
      spacing: 2,
      onMove: (id, index) => {
        const members = runMembers(firstId);
        const target = members[Math.min(index, members.length - 1)];
        if (target) cmux("workspace.reorder", { workspace_id: id, index: target.index });
      },
    },
    (w) => workspaceRow(w, false)
  );
}

// --- root -------------------------------------------------------------------
sidebar(() =>
  VStack({ spacing: 2 }, [
    ForEach(
      { items: sections, key: (s) => s.id },
      (s) => {
        const section = s(); // kind and ids are stable per key
        if (section.kind === "group") {
          return VStack({ spacing: 2 }, [
            groupHeader(section.groupId),
            memberList(section.groupId),
          ]);
        }
        return runList(section.firstId);
      }
    ),
  ])
)
