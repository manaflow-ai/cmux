// agents-dense: maximum agents per pixel. One monospace line per session,
// aligned columns, color only where it means something - the tmux status
// bar aesthetic for people running twenty agents at once.
//   cmux right-sidebar set custom agents-dense

const TINT = {
  needs_input: "#FF9F0A",
  working: "#0A84FF",
  idle: "#34C759",
  ended: "#7f7f7f66",
};
const GLYPH = { claude: "cl", codex: "cx" };

const [query, setQuery] = signal("");
const epoch = () => data.clock()?.epoch ?? 0;

function fmt(secs) {
  const s = Math.max(0, Math.floor(secs));
  if (s < 60) return String(s) + "s";
  const m = Math.floor(s / 60);
  if (m < 60) return String(m) + "m";
  return Math.floor(m / 60) + "h";
}

const rows = computed(() => {
  const q = query().trim().toLowerCase();
  const out = [];
  for (const w of data.workspaces() ?? []) {
    for (const a of w.agents ?? []) {
      const hay = ((a.title ?? "") + " " + w.title + " " + (a.kind ?? "")).toLowerCase();
      if (q && !hay.includes(q)) continue;
      out.push({ key: w.id + ":" + a.id, ws: w, a });
    }
  }
  out.sort((x, y) => (x.key < y.key ? -1 : 1));
  return out;
});

const counts = computed(() => {
  let needs = 0, working = 0;
  for (const e of rows()) {
    if (e.a.status === "needs_input") needs += 1;
    if (e.a.status === "working") working += 1;
  }
  return { needs, working };
});

function jump(e) {
  cmux("workspace.select", { workspace_id: e.ws.id });
  if (e.a.surfaceId) cmux("surface.focus", { surface_id: e.a.surfaceId });
}

sidebar(() =>
  VStack({ spacing: 4 }, [
    HStack({ spacing: 6 }, [
      Text("agents").font(11).monospaced().weight("semibold"),
      Spacer(),
      Text(() => counts().needs + "!").font(10).monospaced()
        .color(() => (counts().needs ? "#FF9F0A" : "tertiary")),
      Text(() => counts().working + "~").font(10).monospaced()
        .color(() => (counts().working ? "#0A84FF" : "tertiary")),
      Text(() => String(rows().length)).font(10).monospaced().color("tertiary"),
    ]).paddingHorizontal(10),

    TextField("", {
      placeholder: "filter",
      autofocus: false,
      onEdit: (t) => setQuery(t ?? ""),
    }).font(11).paddingHorizontal(10),

    ForEach({ items: rows, key: (e) => e.key }, (e) =>
      HStack({ spacing: 6 }, [
        Circle({ size: 5 }).fill(() => TINT[e().a.status] ?? TINT.ended),
        Text(() => GLYPH[e().a.kind] ?? "··")
          .font(10).monospaced().color("tertiary")
          .frame({ width: 16, alignment: "leading" }),
        Text(() => (e().a.sinceEpoch ? fmt(epoch() - e().a.sinceEpoch)
          : e().a.lastActivityAt ? fmt(epoch() - e().a.lastActivityAt) : ""))
          .font(10).monospaced().color("tertiary")
          .frame({ width: 28, alignment: "trailing" }),
        Text(() => e().ws.title)
          .font(10).monospaced().color("secondary")
          .lineLimit(1).truncation("tail")
          .frame({ width: 64, alignment: "leading" }),
        Text(() => e().a.title || e().a.name)
          .font(10).monospaced().lineLimit(1).truncation("tail"),
        Spacer({ minLength: 0 }),
      ])
        .paddingHorizontal(10).paddingVertical(3)
        .cornerRadius(5)
        .hoverBackground("#7f7f7f24")
        .frame({ maxWidth: "infinity" })
        .onTap(() => jump(e()))
    ),

    Text(() => (rows().length === 0 ? (query().trim() ? "no match" : "none") : ""))
      .font(10).monospaced().color("tertiary").paddingHorizontal(10),
    Spacer(),
  ]).paddingHorizontal(6),
  { surface: "glass" }
)
