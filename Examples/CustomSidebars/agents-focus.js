// agents-focus: one agent at a time. The single most urgent session gets a
// hero card (needs-input first, then longest-working); everything else is a
// quiet queue below. For people who treat agents like a checkout line.
//   cmux right-sidebar set custom agents-focus

const TINT = {
  needs_input: "#FF9F0A",
  working: "#0A84FF",
  idle: "#34C759",
  ended: "#7f7f7f66",
};
const HEADLINE = {
  needs_input: "Needs your input",
  working: "Working",
  idle: "Idle",
  ended: "Ended",
};
const RANK = { needs_input: 0, working: 1, idle: 2, ended: 3 };

const epoch = () => data.clock()?.epoch ?? 0;

function fmt(secs) {
  const s = Math.max(0, Math.floor(secs));
  if (s < 60) return s + "s";
  const m = Math.floor(s / 60);
  if (m < 60) return m + "m " + String(s % 60).padStart(2, "0") + "s";
  return Math.floor(m / 60) + "h " + String(m % 60).padStart(2, "0") + "m";
}

const ordered = computed(() => {
  const out = [];
  for (const w of data.workspaces() ?? []) {
    for (const a of w.agents ?? []) out.push({ key: w.id + ":" + a.id, ws: w, a });
  }
  out.sort((x, y) => {
    const r = (RANK[x.a.status] ?? 9) - (RANK[y.a.status] ?? 9);
    if (r !== 0) return r;
    // Within a rank the LONGEST-waiting first: oldest since-timestamp wins.
    return (x.a.sinceEpoch ?? x.a.lastActivityAt ?? 0) - (y.a.sinceEpoch ?? y.a.lastActivityAt ?? 0);
  });
  return out;
});
const hero = computed(() => ordered()[0] ?? null);
const queue = computed(() => ordered().slice(1));

function jump(e) {
  cmux("workspace.select", { workspace_id: e.ws.id });
  if (e.a.surfaceId) cmux("surface.focus", { surface_id: e.a.surfaceId });
}

sidebar(() =>
  VStack({ spacing: 10 }, [
    // Hero: the one to deal with.
    VStack({ spacing: 6 }, [
      HStack({ spacing: 6 }, [
        Circle({ size: 8 }).fill(() => (hero() ? TINT[hero().a.status] : "#7f7f7f44")),
        Text(() => (hero() ? HEADLINE[hero().a.status] ?? hero().a.status : "All clear"))
          .font(11).weight("semibold")
          .color(() => (hero() ? TINT[hero().a.status] : "tertiary")),
        Spacer(),
        Text(() => (hero()?.a.sinceEpoch ? fmt(epoch() - hero().a.sinceEpoch) : ""))
          .font(11).monospaced().color("secondary"),
      ]),
      Text(() => hero()?.a.title || hero()?.a.name || "No agents running")
        .font(15).weight("semibold").lineLimit(3),
      Text(() => (hero() ? hero().ws.title + (hero().a.directory ? " · " + hero().a.directory : "") : "Start one in any cmux terminal."))
        .font(10).color("tertiary").lineLimit(1).truncation("middle"),
      HStack({}, [
        Text("Jump to terminal")
          .font(11).weight("semibold")
          .paddingHorizontal(10).paddingVertical(5)
          .cornerRadius(7)
          .background("#7f7f7f2e")
          .hoverBackground("#7f7f7f45")
          .opacity(() => (hero() ? 1 : 0))
          .onTap(() => { if (hero()) jump(hero()); }),
        Spacer(),
      ]),
    ])
      .paddingHorizontal(12).paddingVertical(10)
      .cornerRadius(12)
      .background("#7f7f7f1c")
      .frame({ maxWidth: "infinity" }),

    // The quiet queue.
    Text(() => (queue().length ? "UP NEXT" : ""))
      .font(10).weight("semibold").color("tertiary").paddingHorizontal(10),
    ForEach({ items: queue, key: (e) => e.key }, (e) =>
      HStack({ spacing: 8 }, [
        Circle({ size: 6 }).fill(() => TINT[e().a.status] ?? TINT.ended),
        Text(() => e().a.title || e().a.name)
          .font(11).color("secondary").lineLimit(1).truncation("tail"),
        Spacer(),
        Text(() => e().ws.title).font(10).color("tertiary").lineLimit(1),
      ])
        .paddingHorizontal(10).paddingVertical(5)
        .cornerRadius(7)
        .hoverBackground("#7f7f7f24")
        .frame({ maxWidth: "infinity" })
        .onTap(() => jump(e()))
    ),
    Spacer(),
  ]).paddingHorizontal(6),
  { surface: "glass" }
)
