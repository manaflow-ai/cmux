// agents-cards: one card per subagent with a status-tinted edge. The card
// shape gives each agent room for a second line of context (kind, cwd tail)
// without the row noise of a table - good at a dozen agents or fewer.
//   cmux right-sidebar set custom agents-cards

const TINT = {
  needs_input: "#FF9F0A",
  working: "#0A84FF",
  idle: "#34C759",
  ended: "#7f7f7f66",
};
const LABEL = {
  needs_input: "needs input",
  working: "working",
  idle: "idle",
  ended: "ended",
};

const epoch = () => data.clock()?.epoch ?? 0;

function fmt(secs) {
  const s = Math.max(0, Math.floor(secs));
  if (s < 60) return s + "s";
  const m = Math.floor(s / 60);
  if (m < 60) return m + "m " + String(s % 60).padStart(2, "0") + "s";
  return Math.floor(m / 60) + "h " + String(m % 60).padStart(2, "0") + "m";
}

function tail(path) {
  const parts = String(path ?? "").split("/").filter(Boolean);
  return parts.length ? parts[parts.length - 1] : "";
}

const cards = computed(() => {
  const out = [];
  for (const w of data.workspaces() ?? []) {
    for (const a of w.agents ?? []) out.push({ key: w.id + ":" + a.id, ws: w, a });
  }
  out.sort((x, y) => (x.key < y.key ? -1 : 1));
  return out;
});

function jump(e) {
  cmux("workspace.select", { workspace_id: e.ws.id });
  if (e.a.surfaceId) cmux("surface.focus", { surface_id: e.a.surfaceId });
}

sidebar(() =>
  VStack({ spacing: 8 }, [
    HStack({ spacing: 6 }, [
      Text("Agents").font(14).weight("semibold"),
      Spacer(),
      Text(() => String(cards().length)).font(11).monospaced().color("tertiary"),
    ]).paddingHorizontal(10),

    ForEach({ items: cards, key: (e) => e.key }, (e) =>
      HStack({ spacing: 0 }, [
        // Status edge: a thin tinted rail, the card's only strong color.
        RoundedRectangle({ width: 3, cornerRadius: 2 })
          .fill(() => TINT[e().a.status] ?? TINT.ended)
          .frame({ height: 40 }),
        VStack({ spacing: 2 }, [
          HStack({ spacing: 6 }, [
            Text(() => e().a.title || e().a.name)
              .font(12).weight("semibold").lineLimit(1).truncation("tail"),
            Spacer({ minLength: 0 }),
            Text(() => (e().a.sinceEpoch ? fmt(epoch() - e().a.sinceEpoch) : ""))
              .font(10).monospaced().color("tertiary"),
          ]),
          HStack({ spacing: 5 }, [
            Text(() => LABEL[e().a.status] ?? e().a.status)
              .font(10)
              .color(() => TINT[e().a.status] ?? "tertiary"),
            Text(() => "· " + e().ws.title).font(10).color("tertiary")
              .lineLimit(1).truncation("tail"),
            Text(() => (e().a.directory ? "· " + tail(e().a.directory) : ""))
              .font(10).color("tertiary").lineLimit(1),
            Spacer({ minLength: 0 }),
          ]),
        ]).paddingLeading(9),
      ])
        .paddingHorizontal(10).paddingVertical(7)
        .cornerRadius(10)
        .background("#7f7f7f14")
        .hoverBackground("#7f7f7f28")
        .frame({ maxWidth: "infinity" })
        .onTap(() => jump(e()))
    ),

    Text(() => (cards().length === 0 ? "No agents. Sessions started in cmux terminals appear here." : ""))
      .font(11).color("tertiary").paddingHorizontal(10),
    Spacer(),
  ]).paddingHorizontal(6),
  { surface: "glass" }
)
