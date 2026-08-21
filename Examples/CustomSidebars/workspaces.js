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

// --- optimistic UI -------------------------------------------------------------
// Every user action flips local state the same frame; the cmux command runs
// behind it and the authoritative data context (which refreshes about once a
// second) reconciles: each override clears itself as soon as the data agrees.
let selectOverride = null;
const [selectTick, setSelectTick] = signal(0);

function isSelected(w) {
  selectTick();
  if (!w) return false;
  if (selectOverride) {
    if (data.selectedId() === selectOverride) selectOverride = null; // caught up
    else return w.id === selectOverride;
  }
  return !!w.selected;
}

function selectWorkspace(id) {
  if (!id) return;
  selectOverride = id;
  setSelectTick(selectTick() + 1);
  cmux("workspace.select", { workspace_id: id });
}

const closedOverride = new Set();
const [closeTick, setCloseTick] = signal(0);

function visibleWorkspaces() {
  closeTick();
  const ws = data.workspaces() ?? [];
  for (const id of Array.from(closedOverride)) {
    if (!ws.some((w) => w.id === id)) closedOverride.delete(id); // caught up
  }
  return ws.filter((w) => !closedOverride.has(w.id));
}

function closeWorkspace(id) {
  closedOverride.add(id);
  setCloseTick(closeTick() + 1);
  cmux("workspace.close", { workspace_id: id });
}

const titleOverride = new Map();
const [titleTick, setTitleTick] = signal(0);

function displayTitle(w) {
  titleTick();
  if (!w) return "";
  if (titleOverride.has(w.id)) {
    const t = titleOverride.get(w.id);
    if (w.title === t) titleOverride.delete(w.id); // caught up
    else return t;
  }
  return w.title;
}

// --- inline rename -----------------------------------------------------------
// Double-click a row/header (or its Rename menu item) to edit in place.
// Editing swaps the entry's key, so the keyed reconciler remounts the row as
// an editor; Return commits through workspace(.group).rename, Escape cancels.
const [editingId, setEditingId] = signal(null);

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
const membersOf = (id) => visibleWorkspaces().filter((w) => w.group === id);
// The anchor workspace IS the header (matching the built-in sidebar).
const memberRowsOf = (id) => {
  const g = groupById(id);
  return membersOf(id).filter((w) => !g || w.id !== g.anchorId);
};

// One flat entry list: a group renders (header + expanded member rows) at its
// first member's position; ungrouped workspaces are plain rows.
const flatEntries = computed(() => {
  const ws = visibleWorkspaces();
  const groups = new Map((data.groups() ?? []).map((g) => [g.id, g]));
  const out = [];
  const seen = new Set();
  const editing = editingId();
  const wsEntry = (w, groupId) => ({
    kind: "ws",
    id: w.id + (editing === w.id ? ":edit" : ""),
    wsId: w.id,
    editing: editing === w.id,
    groupId,
  });
  for (const w of ws) {
    if (w.group && groups.has(w.group)) {
      if (seen.has(w.group)) continue;
      seen.add(w.group);
      const g = groups.get(w.group);
      out.push({
        kind: "header",
        id: "h:" + g.id + (editing === "h:" + g.id ? ":edit" : ""),
        groupId: g.id,
        editing: editing === "h:" + g.id,
      });
      if (!isCollapsed(g)) {
        for (const m of memberRowsOf(g.id)) {
          out.push(wsEntry(m, g.id));
        }
      }
    } else if (!w.group) {
      out.push(wsEntry(w, null));
    }
  }
  return out;
});

// --- drop resolution ---------------------------------------------------------
// `index` is the dragged row's slot in the flat list (headers included).
// `extra.side` resolves the ambiguous boundary slots: "above" nests with the
// row above (e.g. last item of a group), "below" with the row below (right
// after the group, outside it) - chosen by the pointer's X position mid-drag.
// Dragging a group HEADER moves the whole block (extra.block).
function handleMove(id, index, extra) {
  const ws = data.workspaces() ?? [];

  if (extra && extra.block && id.startsWith("h:")) {
    const gid = id.slice(2);
    const memberCount = membersOf(gid).length;
    const entries = flatEntries().filter((e) => e.id !== id && e.groupId !== gid);
    const nextEntry = entries.slice(index).find((e) => e.kind === "ws");
    const nextWorkspace = nextEntry ? ws.find((w) => w.id === (nextEntry.wsId ?? nextEntry.id)) : null;
    const anchor = ws.find((w) => w.id === (groupById(gid)?.anchorId));
    let to;
    if (nextWorkspace) {
      const movingDown = (anchor?.index ?? 0) < nextWorkspace.index;
      to = movingDown ? nextWorkspace.index - memberCount : nextWorkspace.index;
    } else {
      to = ws.length - memberCount;
    }
    cmux("workspace.group.move", { group_id: gid, to_index: Math.max(0, to) });
    return;
  }

  const dragged = ws.find((w) => w.id === id);
  if (!dragged) return;
  const entries = flatEntries().filter((e) => e.id !== id);
  const prev = index > 0 ? entries[index - 1] : null;
  const nextEntry = entries.slice(index).find((e) => e.kind === "ws");
  const nextAny = index < entries.length ? entries[index] : null;
  const nextWorkspace = nextEntry ? ws.find((w) => w.id === (nextEntry.wsId ?? nextEntry.id)) : null;

  let container;
  if (extra && extra.side === "below") {
    // Nest with what's below: a header below means "above the next group",
    // i.e. ungrouped; a row below means its group (or ungrouped).
    container = nextAny && nextAny.kind === "ws" ? nextAny.groupId : null;
  } else {
    container = prev ? prev.groupId : null;
    // Dropping right below a collapsed group's header means "after the whole
    // group", not "into it" (its rows are hidden), unless it lives there.
    if (prev && prev.kind === "header") {
      const g = groupById(prev.groupId);
      if (g && isCollapsed(g) && dragged.group !== g.id) container = null;
    }
  }

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
    Button("Rename", () => setEditingId(w().id)),
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
    Text(() => displayTitle(w()))
      .font(13)
      .lineLimit(1)
      .truncation("tail")
      .color(() => (isSelected(w()) ? "primary" : "secondary")),
    Spacer(),
    ZStack({}, [
      // Unread badge at rest; on hover it yields to the close button.
      Text(() => (w()?.unread > 0 ? String(w().unread) : ""))
        .font("caption2").bold().color("white")
        .paddingHorizontal(5).paddingVertical(1)
        .background(() => (w()?.unread > 0 ? "#E4573D" : null))
        .cornerRadius(7)
        .hideOnHover(),
      Image("xmark")
        .font(9).weight("semibold").color("secondary")
        .paddingHorizontal(4).paddingVertical(3)
        .cornerRadius(5)
        .hoverBackground("#7f7f7f38")
        .showOnHover()
        .onTap(() => closeWorkspace(w().id)),
    ]),
  ])
    .paddingHorizontal(10)
    .paddingVertical(6)
    .marginLeading(() => (entry().groupId ? 14 : 0))
    .cornerRadius(8)
    .background(() => (isSelected(w()) ? "#7f7f7f3d" : null))
    .hoverBackground(() => (isSelected(w()) ? "#7f7f7f3d" : "#7f7f7f24"))
    .frame({ maxWidth: "infinity" })
    .block(() => (entry().groupId ? "h:" + entry().groupId : null))
    .onTap(() => selectWorkspace(w().id))
    .onDoubleTap(() => setEditingId(w().id))
    .contextMenu(workspaceMenu(w));
}

// In-place editor row (same box as a workspace row).
function workspaceEditRow(w, entry) {
  return HStack({ spacing: 8 }, [
    TextField(() => w()?.title ?? "", {
      placeholder: "Workspace name",
      onSubmit: (t) => {
        const title = (t ?? "").trim();
        if (title) {
          titleOverride.set(w().id, title);
          setTitleTick(titleTick() + 1);
          cmux("workspace.action", { action: "rename", workspace_id: w().id, title });
        } else {
          cmux("workspace.action", { action: "clear_name", workspace_id: w().id });
        }
        setEditingId(null);
      },
      onCancel: () => setEditingId(null),
    }).font(13),
  ])
    .paddingHorizontal(10)
    .paddingVertical(6)
    .cornerRadius(8)
    .background("#7f7f7f3d")
    .marginLeading(() => (entry().groupId ? 14 : 0))
    .frame({ maxWidth: "infinity" });
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
    // Fixed box: chevron.right and chevron.down have different intrinsic
    // sizes, and letting them dictate layout changed the header height on
    // every toggle.
    Image(() => (isCollapsed(g()) ? "chevron.right" : "chevron.down"))
      .font(10).weight("semibold").color("tertiary")
      .frame({ width: 14, height: 16 })
      .onTap(() => toggleCollapse(g())),
    Text(() => g().name).font(12).weight("semibold").lineLimit(1).truncation("tail")
      .color(() => (isSelected(anchor()) ? "primary" : "secondary")),
    Spacer(),
    Text(() => String(membersOf(groupId).length))
      .font("caption2").color("tertiary").monospaced(),
  ])
    .paddingLeading(8)
    .paddingTrailing(10)
    .paddingVertical(5)
    .cornerRadius(8)
    .background(() => (isSelected(anchor()) ? "#7f7f7f3d" : null))
    .hoverBackground(() => (isSelected(anchor()) ? "#7f7f7f3d" : "#7f7f7f1c"))
    .frame({ maxWidth: "infinity" })
    .fixed()
    .block("h:" + groupId)
    .onTap(() => selectWorkspace(anchor()?.id))
    .onDoubleTap(() => setEditingId("h:" + groupId))
    .contextMenu([
      Button("Rename Group", () => setEditingId("h:" + groupId)),
      Button(() => (isCollapsed(g()) ? "Expand" : "Collapse"), () => toggleCollapse(g())),
      Button(() => (g().pinned ? "Unpin Group" : "Pin Group"), () =>
        cmux("workspace.group.action", { group_id: groupId, action: g().pinned ? "unpin" : "pin" })),
      Divider(),
      Button("Ungroup", groupAct("ungroup")),
      Button("Delete Group", groupAct("delete")).destructive(),
    ]);
}

// Identical geometry to groupHeader (chevron box, paddings, semibold 12)
// so entering/leaving rename changes nothing but the text becoming editable.
function groupEditRow(groupId) {
  const g = () => groupById(groupId);
  return HStack({ spacing: 6 }, [
    Image(() => (isCollapsed(g() ?? {}) ? "chevron.right" : "chevron.down"))
      .font(10).weight("semibold").color("tertiary")
      .frame({ width: 14, height: 16 }),
    TextField(() => g()?.name ?? "", {
      placeholder: "Group name",
      onSubmit: (t) => {
        const name = (t ?? "").trim();
        if (name) cmux("workspace.group.rename", { group_id: groupId, name });
        setEditingId(null);
      },
      onCancel: () => setEditingId(null),
    }).font(12).weight("semibold"),
  ])
    .paddingLeading(8)
    .paddingTrailing(10)
    .paddingVertical(5)
    .cornerRadius(8)
    .background("#7f7f7f3d")
    .frame({ maxWidth: "infinity" })
    .fixed();
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
      const entry = e(); // kind, ids, and editing are stable per key
      if (entry.kind === "header") {
        return entry.editing ? groupEditRow(entry.groupId) : groupHeader(entry.groupId);
      }
      const w = () => (data.workspaces() ?? []).find((x) => x.id === entry.wsId);
      return entry.editing ? workspaceEditRow(w, e) : workspaceRow(w, e);
    }
  ),
  { surface: "glass" }
)
