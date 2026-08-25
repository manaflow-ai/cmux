// agents-board: subagents grouped by STATUS, attention first. The question
// this layout answers is "what needs me right now" - needs-input sessions
// get the loudest section at the top, everything else stays quiet.
//   cmux right-sidebar set custom agents-board

const STATUS_META = {
  needs_input: { label: "NEEDS YOU", color: "#FF9F0A", strong: true },
  working: { label: "WORKING", color: "#0A84FF", strong: false },
  idle: { label: "IDLE", color: "#34C759", strong: false },
  ended: { label: "ENDED", color: "#7f7f7f66", strong: false },
};
const ORDER = ["needs_input", "working", "idle", "ended"];

const epoch = () => data.clock()?.epoch ?? 0;

function fmt(secs) {
  const s = Math.max(0, Math.floor(secs));
  if (s < 60) return s + "s";
  const m = Math.floor(s / 60);
  if (m < 60) return m + "m";
  return Math.floor(m / 60) + "h";
}

const allAgents = computed(() => {
  const out = [];
  for (const w of data.workspaces() ?? []) {
    for (const a of w.agents ?? []) {
      out.push({ key: w.id + ":" + a.id, ws: w, a });
    }
  }
  // Stable within a section: never resort on activity, rows update in place.
  out.sort((x, y) => (x.key < y.key ? -1 : 1));
  return out;
});

const byStatus = (status) => () => allAgents().filter((e) => e.a.status === status);

function jump(e) {
  cmux("workspace.select", { workspace_id: e.ws.id });
  if (e.a.surfaceId) cmux("surface.focus", { surface_id: e.a.surfaceId });
}

function row(e, strong) {
  const meta = () => STATUS_META[e().a.status] ?? STATUS_META.ended;
  return HStack({ spacing: 8 }, [
    Circle({ size: 7 }).fill(() => meta().color),
    VStack({ spacing: 1 }, [
      Text(() => e().a.title || e().a.name)
        .font(12).weight(strong ? "semibold" : "regular")
        .lineLimit(1).truncation("tail"),
      Text(() => {
        const running = (e().a.children ?? []).filter((c) => c.running).length;
        return e().ws.title + (running ? " · " + running + " sub" : "");
      })
        .font(10).color("tertiary").lineLimit(1).truncation("tail"),
    ]),
    Spacer({ minLength: 0 }),
    Text(() => (e().a.sinceEpoch ? fmt(epoch() - e().a.sinceEpoch)
      : e().a.lastActivityAt ? fmt(epoch() - e().a.lastActivityAt) : ""))
      .font(10).monospaced().color("tertiary"),
  ])
    .paddingHorizontal(10).paddingVertical(6)
    .cornerRadius(8)
    .background(() => (strong ? "#FF9F0A1a" : null))
    .hoverBackground(strong ? "#FF9F0A2e" : "#7f7f7f24")
    .frame({ maxWidth: "infinity" })
    .onTap(() => jump(e()));
}

function statusSection(status) {
  const meta = STATUS_META[status];
  const items = byStatus(status);
  return VStack({ spacing: 3 }, [
    HStack({ spacing: 6 }, [
      Text(meta.label).font(10).weight("semibold")
        .color(() => (items().length && meta.strong ? meta.color : "tertiary")),
      Spacer(),
      Text(() => (items().length ? String(items().length) : ""))
        .font(10).monospaced().color("tertiary"),
    ]).paddingHorizontal(10),
    ForEach({ items, key: (e) => e.key }, (e) => row(e, meta.strong)),
    Text(() => (items().length === 0 ? "—" : ""))
      .font(10).color("tertiary").paddingHorizontal(10),
  ]);
}

sidebar(() =>
  VStack({ spacing: 10 }, [
    Text("Agents").font(14).weight("semibold").paddingHorizontal(10),
    ...ORDER.map(statusSection),
    Spacer(),
  ]).paddingHorizontal(6),
  { surface: "glass" }
)
