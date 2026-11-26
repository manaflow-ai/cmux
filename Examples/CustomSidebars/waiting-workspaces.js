// A window-local queue for agent questions. Sorting changes this view only.
// Install: copy this file into ~/.config/cmux/sidebars/ and select waiting-workspaces.
const statuses = { needs_input: "Waiting for you", working: "Working", idle: "Idle", ended: "Ended" };
const priority = { ended: 1, idle: 2, working: 3, needs_input: 4 };
let observedStarts = new Map();

function workspaceRow(workspace, nextStarts, observedAt) {
  const tabs = workspace.tabs ?? [];
  const bySurface = new Map();
  const byPanel = new Map();
  const surfaces = tabs.map((tab) => {
    const row = {
      id: tab.id, surfaceId: tab.surfaceId, title: tab.title, branch: tab.branch,
      dirty: tab.dirty, directory: tab.directory, prompt: tab.latestPrompt,
      selected: workspace.selected && tab.focused, pinned: tab.pinned, status: "", rank: 0, wait: null,
    };
    if (tab.surfaceId) bySurface.set(tab.surfaceId, row);
    byPanel.set(tab.id, row);
    return row;
  });
  // The host provides sessions newest first. A different surface id can belong
  // to an earlier remote tmux pane, even when the panel id still matches.
  for (const agent of workspace.agents ?? []) {
    const tab = agent.surfaceId ? bySurface.get(agent.surfaceId) : byPanel.get(agent.panelId);
    if (!tab) continue;
    const rank = priority[agent.status] ?? 0;
    if (rank > tab.rank) {
      tab.rank = rank;
      tab.status = statuses[agent.status];
    }
    if (agent.status !== "needs_input" || !tab.surfaceId) continue;
    const key = JSON.stringify([workspace.id, tab.surfaceId, agent.id]);
    const start = agent.sinceEpoch ?? observedStarts.get(key) ?? observedAt;
    nextStarts.set(key, start);
    tab.wait = tab.wait === null ? start : Math.min(tab.wait, start);
  }
  const waiting = surfaces.filter((tab) => tab.wait !== null).sort((a, b) => a.wait - b.wait);
  return {
    id: workspace.id, group: workspace.group, pinned: workspace.pinned, selected: workspace.selected,
    title: workspace.title, description: workspace.description, prompt: workspace.latestPrompt,
    surfaces: surfaces.sort((a, b) => {
      if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
      if (a.wait === null || b.wait === null) return Number(a.wait === null) - Number(b.wait === null);
      return a.wait - b.wait;
    }), waiting,
  };
}

function waitOrder(a, b) {
  if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
  if (a.waiting.length && b.waiting.length) return a.waiting[0].wait - b.waiting[0].wait;
  return Number(Boolean(b.waiting.length)) - Number(Boolean(a.waiting.length));
}

const view = computed(() => {
  const nextStarts = new Map();
  const observedAt = Date.now() / 1000;
  const workspaces = (data.workspaces() ?? []).map((w) => workspaceRow(w, nextStarts, observedAt));
  observedStarts = nextStarts;
  const groups = new Map((data.groups() ?? []).map((g) => [g.id, { ...g, members: [] }]));
  const loose = [];
  const queue = [];
  for (const workspace of workspaces) {
    const group = groups.get(workspace.group);
    if (group) group.members.push(workspace);
    else loose.push(workspace);
    for (const tab of workspace.waiting) {
      queue.push({ workspaceId: workspace.id, surfaceId: tab.surfaceId, start: tab.wait });
    }
  }
  queue.sort((a, b) => a.start - b.start);
  loose.sort(waitOrder);
  const rows = [];
  function appendGroup(group) {
    const waitingCount = group.members.filter((w) => w.waiting.length).length;
    rows.push({ kind: "group", id: group.id, title: group.name, collapsed: group.collapsed, waitingCount });
    if (!group.collapsed) {
      for (const member of group.members.sort(waitOrder)) rows.push({ kind: "workspace", ...member });
    }
  }
  // Headers with no surviving workspace still have a position in data.groups.
  // Insert each before the next live group in its tier, or at the end of the tier.
  for (const pinned of [true, false]) {
    const byAnchor = new Map();
    let empty = [];
    for (const group of groups.values()) {
      if (Boolean(group.pinned) !== pinned) continue;
      if (!group.members.length) {
        empty.push(group);
        continue;
      }
      const anchor = group.members.find((w) => w.id === group.anchorId) ?? group.members[0];
      byAnchor.set(anchor.id, [...empty, group]);
      empty = [];
    }
    const looseInTier = loose.filter((w) => Boolean(w.pinned) === pinned);
    let looseIndex = 0;
    for (const workspace of workspaces) {
      if (byAnchor.has(workspace.id)) {
        for (const group of byAnchor.get(workspace.id)) appendGroup(group);
      } else if (!groups.has(workspace.group) && Boolean(workspace.pinned) === pinned) {
        rows.push({ kind: "workspace", ...looseInTier[looseIndex++] });
      }
    }
    for (const group of empty) appendGroup(group);
  }
  return { rows, queue };
});

function focusSurface(workspaceId, surfaceId) {
  if (surfaceId) cmux("surface.focus", { workspace_id: workspaceId, surface_id: surfaceId });
}

function optionalText(readValue, style) {
  return ForEach({
    items: () => {
      const value = readValue();
      return value ? [{ id: "detail", value }] : [];
    },
  }, (item) => style(Text(() => item().value).help(() => item().value)));
}

function metadataLine(symbol, text, expanded) {
  return HStack({ spacing: 5 }, [
    Image(symbol).font(9).color("secondary"),
    text.font(10).monospaced().color("secondary").lineLimit(() => expanded() ? null : 1)
      .truncation("middle"),
  ]);
}

function surfaceRow(workspaceId, tab, expanded) {
  return VStack({ alignment: "leading", spacing: 2 }, [
    HStack({ spacing: 5 }, [
      Image(() => tab().wait === null ? "terminal" : "questionmark.circle.fill")
        .font(11).color(() => tab().wait === null ? "secondary" : "orange"),
      Text(() => tab().title).font(11).lineLimit(1).help(() => tab().title),
      Spacer(),
      Text(() => tab().status).font(10)
        .weight(() => tab().wait === null ? "regular" : "semibold")
        .color(() => tab().wait === null ? "secondary" : "primary"),
    ]),
    optionalText(() => tab().branch && (tab().branch + (tab().dirty ? " *" : "")),
      (text) => metadataLine("arrow.triangle.branch", text, expanded)),
    optionalText(() => tab().directory,
      (text) => metadataLine("folder", text, expanded)),
    optionalText(() => tab().prompt && "Last prompt: " + tab().prompt,
      (text) => text.font(10).color("secondary").lineLimit(() => expanded() ? null : 1)),
  ]).paddingHorizontal(7).paddingVertical(4).cornerRadius(5)
    .background(() => tab().selected ? "#80808026" : "clear")
    .hoverBackground("#80808024")
    .onTap(() => focusSurface(workspaceId, tab().surfaceId));
}

function workspaceView(row) {
  const [expanded, setExpanded] = signal(false);
  const summary = () => row().description || (row().prompt && "Last prompt: " + row().prompt);
  return VStack({ alignment: "leading", spacing: 3 }, [
    VStack({ alignment: "leading", spacing: 2 }, [
      HStack({ spacing: 6 }, [
        Text(() => row().title).font(13).weight("semibold").lineLimit(1).help(() => row().title),
        Spacer(),
        optionalText(() => row().waiting.length ? "Waiting for you" : "",
          (text) => text.font(10).weight("semibold").color("primary")),
        Text(() => expanded() ? "Less" : "Details")
          .font(10).color("secondary").padding(4).onTap(() => setExpanded(!expanded())),
      ]),
      optionalText(summary, (text) => text.font(11).color("secondary").lineLimit(() => expanded() ? null : 2)),
    ]).paddingVertical(3).onTap(() => {
      const w = row();
      if (w.waiting.length) focusSurface(w.id, w.waiting[0].surfaceId);
      else cmux("workspace.select", { workspace_id: w.id });
    }),
    ForEach({ items: () => row().surfaces }, (tab) => surfaceRow(row().id, tab, expanded)),
  ]).paddingLeading(() => row().group ? 15 : 6).paddingTrailing(6).paddingVertical(5)
    .background(() => row().selected ? "#8080801A" : "clear").cornerRadius(6);
}

function groupView(row) {
  return HStack({ spacing: 5 }, [
    Image(() => row().collapsed ? "chevron.right" : "chevron.down").font(10),
    Image("folder").font(12),
    Text(() => row().title).font(12).weight("semibold").lineLimit(1),
    Spacer(),
    optionalText(() => row().waitingCount ? "Waiting · " + row().waitingCount : "",
      (text) => text.font(11).weight("semibold").color("primary")),
  ]).padding(6).hoverBackground("#80808024").onTap(() => {
    const g = row();
    cmux(g.collapsed ? "workspace.group.expand" : "workspace.group.collapse", { group_id: g.id });
  });
}

sidebar(() => LazyVStack({ alignment: "leading", spacing: 3 }, [
  ForEach({
    items: () => view().queue.length ? [{ id: "oldest", count: view().queue.length }] : [],
  }, (entry) => HStack({ spacing: 6 }, [
    Image("questionmark.circle.fill").color("orange"),
    Text(() => "Waiting for you · " + entry().count).font(13).weight("semibold"),
    Spacer(),
  ]).padding(8).cornerRadius(7).hoverBackground("#80808024").onTap(() => {
    const oldest = view().queue[0];
    if (oldest) focusSurface(oldest.workspaceId, oldest.surfaceId);
  })),
  ForEach({ items: () => view().rows, key: (row) => row.kind + ":" + row.id },
    (row) => row().kind === "group" ? groupView(row) : workspaceView(row)),
]).paddingHorizontal(5));
