// btop-agents: agent activity at a glance, btop style. Every workspace gets
// a braille sparkline of how busy its agents have been over the last few
// minutes, a state glyph, and a tiny progress meter; the header graphs how
// many workspaces are busy right now. Click a row to jump to the workspace,
// drag to reorder, click the ALL/BUSY chip to hide quiet workspaces.
//   cp Examples/CustomSidebars/btop-agents.js ~/.config/cmux/sidebars/
//   cmux sidebar select btop-agents          (or: cmux sidebar open btop-agents)
//
// History lives in this sidebar, sampled once per clock tick, so graphs start
// when the sidebar loads. Sessions that are already working backfill from
// their start time. One graph column is BUCKET seconds.

const BUCKET = 15; // seconds per graph column (two columns per braille cell)
const ROW_CELLS = 12; // per-workspace sparkline: 24 columns = 6 minutes
const TOP_CELLS = 24; // header graph: 48 columns = 12 minutes
const KEEP = TOP_CELLS * 2; // buckets of history kept per workspace
const METER = 6; // progress meter cells
const MAX_ROWS = 40;

// Theme tokens only (system colors adapt to light and dark).
const STATE = {
  needs_input: { glyph: "◆", color: "orange", word: "input" },
  working: { glyph: "", color: "cyan", word: "run" },
  idle: { glyph: "●", color: "green", word: "idle" },
  ended: { glyph: "○", color: "tertiary", word: "done" },
  none: { glyph: "·", color: "quaternary", word: "" },
};
const RANK = { needs_input: 4, working: 3, idle: 2, ended: 1, none: 0 };
const SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
// Graph gradient, bottom dot row to top (btop's cpu box, in system colors).
// No yellow: system yellow braille dots wash out on a light sidebar.
const ROW_HEAT = ["green", "green", "orange", "orange"];
const TOP_HEAT = ["teal", "teal", "green", "green", "green", "orange", "orange", "red"];
const FLOOR = "quaternary"; // the dotted baseline under an idle graph
const PR_COLOR = { open: "green", merged: "purple", closed: "red" };

// "agents" in the Calvin S figlet font.
const BANNER = [
  "┌─┐┌─┐┌─┐┌┐┌┌┬┐┌─┐",
  "├─┤│ ┬├┤ │││ │ └─┐",
  "┴ ┴└─┘└─┘┘└┘ ┴ └─┘",
];
const BANNER_COLORS = ["cyan", "teal", "green"];

// ---------------------------------------------------------------------------
// Braille graphs. A cell is 2 columns x 4 dot rows; bit for each dot row,
// bottom to top, in the left and right column.
const LEFT_DOTS = [0x40, 0x04, 0x02, 0x01];
const RIGHT_DOTS = [0x80, 0x20, 0x10, 0x08];
const BLANK = String.fromCharCode(0x2800);

// levels: one integer per column (0..lines*4). Returns lines top first; each
// line is 5 same-width layer strings: [floor, dot row 1 (bottom) .. dot row 4].
// Layers stack in a ZStack so every dot row gets its own gradient color.
function brailleLayers(levels, lines) {
  const out = [];
  for (let line = lines - 1; line >= 0; line -= 1) {
    const layers = ["", "", "", "", ""];
    for (let c = 0; c + 1 < levels.length; c += 2) {
      const l = Math.max(0, Math.min(4, levels[c] - line * 4));
      const r = Math.max(0, Math.min(4, levels[c + 1] - line * 4));
      let floor = 0;
      if (line === 0) {
        if (l === 0) floor |= LEFT_DOTS[0];
        if (r === 0) floor |= RIGHT_DOTS[0];
      }
      layers[0] += String.fromCharCode(0x2800 + floor);
      for (let k = 0; k < 4; k += 1) {
        const bits = (l > k ? LEFT_DOTS[k] : 0) | (r > k ? RIGHT_DOTS[k] : 0);
        layers[k + 1] += String.fromCharCode(0x2800 + bits);
      }
    }
    out.push(layers);
  }
  return out;
}

function graphLine(layers, heat) {
  return ZStack({ alignment: "leading" }, [
    Text(() => layers()[0]).font(10).monospaced().color(FLOOR),
    ...[1, 2, 3, 4].map((k) =>
      Text(() => layers()[k]).font(10).monospaced().color(heat[k - 1])),
  ]).fixedSize();
}

// ---------------------------------------------------------------------------
// History: wsId -> Map(bucket -> { n: samples, busy: samples with a working agent }).
const history = new Map();
let lastSampled = -1;

const list = (v) => (Array.isArray(v) ? v : []);
const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);

function backfill(h, agents, now) {
  const first = Math.floor(now / BUCKET) - KEEP + 1;
  for (const a of agents) {
    const since = num(a.sinceEpoch);
    if (a.status !== "working" || since === null || since >= now) continue;
    for (let b = Math.max(first, Math.floor(since / BUCKET)); b < Math.floor(now / BUCKET); b += 1) {
      h.set(b, { n: 1, busy: 1 });
    }
  }
}

function oldestEvictableHistory(protectedIds) {
  for (const id of history.keys()) if (!protectedIds.has(id)) return id;
  return null;
}

function sample(workspaces, now, liveIds = new Set(workspaces.map((w) => w.id))) {
  const bucket = Math.floor(now / BUCKET);
  const sampled = new Set(workspaces.map((w) => w.id));
  for (const id of Array.from(history.keys())) if (!liveIds.has(id)) history.delete(id);
  for (const w of workspaces) {
    const agents = list(w.agents);
    let h = history.get(w.id);
    if (!h) {
      if (history.size >= MAX_ROWS) {
        const evicted = oldestEvictableHistory(sampled);
        if (evicted !== null) history.delete(evicted);
      }
      h = new Map();
      backfill(h, agents, now);
    }
    const slot = h.get(bucket) ?? { n: 0, busy: 0 };
    slot.n += 1;
    if (agents.some((a) => a.status === "working")) slot.busy += 1;
    h.set(bucket, slot);
    // Wall-clock corrections can move `bucket` backward. Drop future buckets
    // too, otherwise every clock era leaves another KEEP entries behind.
    for (const b of h.keys()) if (b <= bucket - KEEP || b > bucket) h.delete(b);
    // Map insertion order is the eviction order. Sampling makes this entry
    // most-recently used without retaining more than MAX_ROWS histories.
    history.delete(w.id);
    history.set(w.id, h);
  }
}

// Share of each bucket an agent was working, newest last.
function duty(h, count, bucket) {
  const out = [];
  for (let b = bucket - count + 1; b <= bucket; b += 1) {
    const s = h && h.get(b);
    out.push(s && s.n ? s.busy / s.n : 0);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Row model.
function fmtAge(secs) {
  const s = Math.max(0, Math.floor(secs));
  if (s < 60) return s + "s";
  const m = Math.floor(s / 60);
  if (m < 60) return m + "m";
  const h = Math.floor(m / 60);
  return h < 48 ? h + "h" : Math.floor(h / 24) + "d";
}

function lead(agents) {
  let best = null;
  for (const a of agents) {
    if (!best || (RANK[a.status] ?? 0) > (RANK[best.status] ?? 0)) best = a;
  }
  return best;
}

function rowModel(w, now) {
  const agents = list(w.agents);
  const top = lead(agents);
  const state = top && STATE[top.status] ? top.status : "none";
  const bucket = Math.floor(now / BUCKET);
  const levels = duty(history.get(w.id), ROW_CELLS * 2, bucket)
    .map((d) => (d > 0 ? Math.max(1, Math.round(d * 4)) : 0));
  const progress = w.progress && num(w.progress.value) !== null
    ? Math.max(0, Math.min(1, w.progress.value)) : null;
  const since = top ? num(top.sinceEpoch) ?? num(top.lastActivityAt) : null;
  const age = since !== null && now > 0 ? fmtAge(now - since) : "";
  const pr = w.pr && num(w.pr.number) !== null ? w.pr : null;
  const running = agents.filter((a) => a.status === "working").length;
  return {
    id: w.id,
    title: w.title || "untitled",
    selected: !!w.selected,
    tint: w.color || null,
    state,
    glyph: state === "working" ? SPINNER[now % SPINNER.length] : STATE[state].glyph,
    count: running > 1 ? "×" + running : "",
    unread: num(w.unread) || 0,
    prLabel: pr ? "#" + pr.number : "",
    prColor: pr ? PR_COLOR[pr.status] ?? "secondary" : "secondary",
    prURL: pr ? pr.url || "" : "",
    layers: brailleLayers(levels, 1)[0],
    meterOn: progress === null ? "" : "■".repeat(Math.round(progress * METER)),
    meterOff: progress === null ? "" : "■".repeat(METER - Math.round(progress * METER)),
    meterText: progress === null ? "" : Math.round(progress * 100) + "%",
    status: progress === null && state !== "none" ? STATE[state].word + " " + age : "",
    busy: state === "working" || state === "needs_input" || (num(w.unread) || 0) > 0,
  };
}

function workspaceIsBusy(w) {
  return (num(w.unread) || 0) > 0
    || list(w.agents).some((a) => a.status === "working" || a.status === "needs_input");
}

function cappedWorkspaces(workspaces, onlyBusy) {
  const capped = [];
  let selected = null;
  for (const w of workspaces) {
    if (!selected && w.selected) selected = w;
    if (capped.length < MAX_ROWS && (!onlyBusy || workspaceIsBusy(w) || w.selected)) {
      capped.push(w);
    }
  }
  if (selected && !capped.some((w) => w.id === selected.id)) {
    if (capped.length === MAX_ROWS) capped[MAX_ROWS - 1] = selected;
    else capped.push(selected);
  }
  return capped;
}

const [busyOnly, setBusyOnly] = signal(false);

// Workspace selection changes only when workspace data or the ALL/BUSY mode
// changes. Keep the one-second clock out of this full-list pass; the clocked
// snapshot below should touch only the admitted rows and bounded history.
const workspaceSelection = computed(() => {
  const allWorkspaces = list(data.workspaces());
  return {
    workspaces: cappedWorkspaces(allWorkspaces, busyOnly()),
    liveIds: new Set(allWorkspaces.map((w) => w.id)),
  };
});

const snapshot = computed(() => {
  const now = Math.floor(num(data.clock()?.epoch) ?? 0);
  const selection = workspaceSelection();
  const workspaces = selection.workspaces;
  if (now > 0 && now !== lastSampled) {
    sample(workspaces, now, selection.liveIds);
    lastSampled = now;
  }
  const rows = workspaces.map((w) => rowModel(w, now));

  // Header graph: how many workspaces were busy, per bucket.
  const bucket = Math.floor(now / BUCKET);
  const sums = new Array(TOP_CELLS * 2).fill(0);
  for (const h of history.values()) {
    duty(h, TOP_CELLS * 2, bucket).forEach((d, i) => { sums[i] += d; });
  }
  const peak = Math.max(...sums);
  const scale = Math.max(4, Math.ceil(peak));
  const levels = sums.map((s) => (s > 0 ? Math.max(1, Math.round((s / scale) * 8)) : 0));

  let working = 0, waiting = 0;
  for (const w of workspaces) {
    for (const a of list(w.agents)) {
      if (a.status === "working") working += 1;
      if (a.status === "needs_input") waiting += 1;
    }
  }
  return {
    now,
    rows,
    top: brailleLayers(levels, 2),
    peak: Math.round(peak * 10) / 10,
    working,
    waiting,
    busyCount: rows.filter((r) => r.busy).length,
  };
});

const shown = computed(() => {
  return snapshot().rows;
});

// A drop index counts visible rows; map it onto the full workspace order.
function move(id, index) {
  const all = list(data.workspaces()).map((w) => w.id).filter((x) => x !== id);
  const visible = shown().map((r) => r.id).filter((x) => x !== id);
  let target = index;
  if (visible.length < all.length) {
    target = index < visible.length
      ? all.indexOf(visible[index])
      : all.indexOf(visible[visible.length - 1]) + 1;
  }
  cmux("workspace.reorder", { workspace_id: id, index: Math.max(0, target) });
}

// ---------------------------------------------------------------------------
// Views.
function header() {
  const spin = () => SPINNER[snapshot().now % SPINNER.length];
  return VStack({ spacing: 6 }, [
    HStack({ spacing: 8, alignment: "top" }, [
      VStack({ spacing: 0 }, BANNER.map((line, i) =>
        Text(line).font(10).monospaced().color(BANNER_COLORS[i]))),
      Spacer({ minLength: 0 }),
      VStack({ spacing: 1, alignment: "trailing" }, [
        Text(() => data.clock()?.time ?? "").font(10).monospaced().color("secondary"),
        HStack({ spacing: 3 }, [
          Text(() => (snapshot().working ? spin() : "·")).font(10).monospaced()
            .color(() => (snapshot().working ? STATE.working.color : "quaternary")),
          Text(() => snapshot().working + " run").font(10).monospaced().color("secondary"),
        ]),
        HStack({ spacing: 3 }, [
          Text("◆").font(10).monospaced()
            .color(() => (snapshot().waiting ? STATE.needs_input.color : "quaternary")),
          Text(() => snapshot().waiting + " input").font(10).monospaced()
            .color(() => (snapshot().waiting ? STATE.needs_input.color : "secondary")),
        ]),
      ]).fixedSize(),
    ]),
    VStack({ spacing: 0 }, [0, 1].map((line) =>
      graphLine(() => snapshot().top[line], line === 0 ? TOP_HEAT.slice(4) : TOP_HEAT.slice(0, 4)))),
    HStack({ spacing: 4 }, [
      Text(Math.round((TOP_CELLS * 2 * BUCKET) / 60) + "m").font(9).monospaced().color("tertiary"),
      Text(() => "busy workspaces, peak " + snapshot().peak).font(9).monospaced().color("tertiary")
        .lineLimit(1),
      Spacer({ minLength: 0 }),
      Text("now").font(9).monospaced().color("tertiary"),
    ]),
  ])
    .frame({ maxWidth: "infinity" });
}

function chip(label, active, onTap) {
  return Text(label).font(9).monospaced().weight("semibold")
    .color(() => (active() ? "primary" : "tertiary"))
    .paddingHorizontal(5).paddingVertical(1)
    .cornerRadius(4)
    .background(() => (active() ? "#7f7f7f33" : "clear"))
    .hoverBackground("#7f7f7f26")
    .onTap(onTap);
}

function row(r) {
  const color = () => STATE[r().state].color;
  return HStack({ spacing: 6 }, [
    RoundedRectangle({ width: 3, height: 26, cornerRadius: 1.5 })
      .fill(() => (r().selected ? r().tint ?? "accent" : r().tint ? r().tint + "55" : "clear")),
    VStack({ spacing: 2 }, [
      HStack({ spacing: 5 }, [
        Text(() => r().glyph).font(11).monospaced().color(color)
          .frame({ width: 10, alignment: "center" }),
        Text(() => r().title).font(12)
          .weight(() => (r().selected ? "semibold" : "regular"))
          .color(() => (r().state === "none" && !r().selected ? "secondary" : "primary"))
          .lineLimit(1).truncation("tail"),
        Text(() => r().count).font(9).monospaced().color(color),
        Spacer({ minLength: 0 }),
        Text(() => (r().unread ? "●" + r().unread : "")).font(9).monospaced().color("blue"),
        Text(() => r().prLabel).font(9).monospaced().color(() => r().prColor)
          .paddingHorizontal(2).cornerRadius(3).hoverBackground("#7f7f7f33")
          .onTap(() => { if (r().prURL) openURL(r().prURL); }),
      ]),
      HStack({ spacing: 6 }, [
        graphLine(() => r().layers, ROW_HEAT),
        Spacer({ minLength: 0 }),
        HStack({ spacing: 0 }, [
          Text(() => r().meterOn).font(8).monospaced().color("accent"),
          Text(() => r().meterOff).font(8).monospaced().color("quaternary"),
        ]),
        Text(() => r().meterText || r().status).font(9).monospaced()
          .color(() => (r().meterText ? "secondary" : r().state === "needs_input" ? color() : "tertiary"))
          .lineLimit(1),
      ]).paddingLeading(15),
    ]).frame({ maxWidth: "infinity" }),
  ])
    .paddingHorizontal(6).paddingVertical(4)
    .cornerRadius(6)
    .background(() => (r().selected ? "#7f7f7f1f" : "clear"))
    .hoverBackground("#7f7f7f26")
    .frame({ maxWidth: "infinity" })
    .onTap(() => cmux("workspace.select", { workspace_id: r().id }))
    .contextMenu([
      Button(() => (r().prLabel ? "Open PR " + r().prLabel : "No PR"), () => {
        if (r().prURL) openURL(r().prURL);
      }),
      Button("Mark Read", () => cmux("workspace.action", { workspace_id: r().id, action: "mark_read" })),
    ]);
}

sidebar(() =>
  VStack({ spacing: 6 }, [
    header().paddingHorizontal(8).paddingTop(6),
    HStack({ spacing: 4 }, [
      chip("ALL", () => !busyOnly(), () => setBusyOnly(false)),
      chip("BUSY", busyOnly, () => setBusyOnly(true)),
      Spacer({ minLength: 0 }),
      Text(() => snapshot().busyCount + "/" + snapshot().rows.length + " busy")
        .font(9).monospaced().color("tertiary"),
    ]).paddingHorizontal(8),
    Divider(),
    Reorderable({ items: shown, key: (r) => r.id, onMove: move, spacing: 1 }, row),
    Text(() => (shown().length ? "" : busyOnly() ? "all quiet" : "no workspaces"))
      .font(10).monospaced().color("tertiary").paddingHorizontal(8),
    Spacer(),
  ]).paddingHorizontal(4),
  { surface: "glass" }
)
