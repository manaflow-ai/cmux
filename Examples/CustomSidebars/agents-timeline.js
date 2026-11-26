// agents-timeline: subagents as a recency feed on a vertical rail. Reads
// like a log - the newest activity sits on top with a time gutter, so a
// glance answers "what just happened" rather than "what exists".
//   cmux right-sidebar set custom agents-timeline

const TINT = {
  needs_input: "#FF9F0A",
  working: "#0A84FF",
  idle: "#34C759",
  ended: "#7f7f7f66",
};

const epoch = () => data.clock()?.epoch ?? 0;

function ago(secs) {
  const s = Math.max(0, Math.floor(secs));
  if (s < 60) return "now";
  const m = Math.floor(s / 60);
  if (m < 60) return m + "m";
  const h = Math.floor(m / 60);
  if (h < 24) return h + "h";
  return Math.floor(h / 24) + "d";
}

// Bucket activity to the minute so the feed's ORDER is calm - rows update
// in place every second, but only a minute boundary can reorder them.
const feed = computed(() => {
  const out = [];
  for (const w of data.workspaces() ?? []) {
    for (const a of w.agents ?? []) {
      out.push({ key: w.id + ":" + a.id, ws: w, a, at: Math.floor((a.lastActivityAt ?? 0) / 60) });
    }
  }
  out.sort((x, y) => (y.at - x.at) || (x.key < y.key ? -1 : 1));
  return out;
});

function jump(e) {
  cmux("workspace.select", { workspace_id: e.ws.id });
  if (e.a.surfaceId) cmux("surface.focus", { surface_id: e.a.surfaceId });
}

sidebar(() =>
  VStack({ spacing: 0 }, [
    Text("Activity").font(14).weight("semibold")
      .paddingHorizontal(10).paddingBottom(8),

    ForEach({ items: feed, key: (e) => e.key }, (e) =>
      HStack({ spacing: 0, alignment: "top" }, [
        // Time gutter: fixed-width right-aligned mono column.
        Text(() => ago(epoch() - (e().a.lastActivityAt ?? 0)))
          .font(10).monospaced().color("tertiary")
          .frame({ width: 30, alignment: "trailing" }),
        // Rail: dot plus a connector that ties rows into one line.
        VStack({ spacing: 0 }, [
          Circle({ size: 7 }).fill(() => TINT[e().a.status] ?? TINT.ended),
          Rectangle({ width: 1 }).fill("#7f7f7f2e").frame({ height: 30 }),
        ]).paddingHorizontal(10),
        VStack({ spacing: 1 }, [
          Text(() => e().a.title || e().a.name)
            .font(12).lineLimit(1).truncation("tail"),
          Text(() => e().ws.title + " · " + (e().a.kind ?? ""))
            .font(10).color("tertiary").lineLimit(1).truncation("tail"),
        ])
          .paddingHorizontal(6).paddingVertical(2)
          .cornerRadius(7)
          .hoverBackground("#7f7f7f24")
          .frame({ maxWidth: "infinity" })
          .onTap(() => jump(e())),
      ]).frame({ maxWidth: "infinity" })
    ),

    Text(() => (feed().length === 0 ? "Quiet. Agent activity lands here." : ""))
      .font(11).color("tertiary").paddingHorizontal(10),
    Spacer(),
  ]).paddingHorizontal(6),
  { surface: "glass" }
)
