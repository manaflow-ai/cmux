// Triage: unread workspaces first with one-tap mark-read, everything else
// dimmed below. Uses reactive partitioning, buttons, and hover.
//   cp Examples/CustomSidebars/activity.js ~/.config/cmux/sidebars/ && cmux sidebar open activity

const unread = () => (data.workspaces() ?? []).filter((w) => w.unread > 0);
const read = () => (data.workspaces() ?? []).filter((w) => !(w.unread > 0));

function row(w, dimmed) {
  return HStack({ spacing: 8 }, [
    Text(() => w().title)
      .font(13).lineLimit(1).truncation("tail")
      .color(() => (w().selected ? "primary" : "secondary"))
      .opacity(dimmed ? 0.55 : 1),
    Spacer(),
    Text(() => (w().unread > 0 ? String(w().unread) : ""))
      .font("caption2").bold().color("white")
      .paddingHorizontal(5).paddingVertical(1)
      .background(() => (w().unread > 0 ? "#E4573D" : null))
      .cornerRadius(7),
  ])
    .paddingHorizontal(10).paddingVertical(6)
    .cornerRadius(8)
    .background(() => (w().selected ? "#7f7f7f3d" : null))
    .hoverBackground("#7f7f7f24")
    .frame({ maxWidth: "infinity" })
    .onTap(() => cmux("workspace.select", { workspace_id: w().id }))
    .contextMenu([
      Button(() => (w().unread > 0 ? "Mark as Read" : "Mark as Unread"), () =>
        cmux("workspace.action", {
          action: w().unread > 0 ? "mark_read" : "mark_unread",
          workspace_id: w().id,
        })),
    ]);
}

sidebar(() =>
  VStack({ spacing: 6 }, [
    Text(() => "Inbox " + (data.unreadTotal() > 0 ? "(" + data.unreadTotal() + ")" : ""))
      .font("headline").paddingHorizontal(10),
    Divider(),
    ForEach({ items: unread, key: (w) => w.id }, (w) => row(w, false)),
    Text(() => (unread().length === 0 ? "Nothing unread" : ""))
      .font("caption").color("tertiary").paddingHorizontal(10),
    Divider(),
    ForEach({ items: read, key: (w) => w.id }, (w) => row(w, true)),
  ]),
  { surface: "glass" }
)
