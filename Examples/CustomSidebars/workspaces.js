// Dia-style workspace sidebar for the cmux JS scene runtime.
//
// One-line rows, no chrome: hover shows a soft squircle wash, the selected
// workspace holds a stronger one, unread counts sit flush right. Rows are
// drag-reorderable (grab and move; the drop persists via workspace.reorder)
// and keep stable identity by workspace id, so animations and an in-flight
// drag survive live data updates.
//
// Install:  cp Examples/CustomSidebars/workspaces.js ~/.config/cmux/sidebars/
// Open:     cmux sidebar open workspaces

sidebar(() =>
  Reorderable(
    {
      items: () => data.workspaces() ?? [],
      key: (w) => w.id,
      spacing: 2,
      onMove: (id, index) =>
        cmux("workspace.reorder", { workspace_id: id, index: index }),
    },
    (w) =>
      HStack({ spacing: 8 }, [
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
        .paddingHorizontal(10)
        .paddingVertical(6)
        .cornerRadius(8)
        .background(() => (w().selected ? "#7f7f7f3d" : null))
        .hoverBackground(() => (w().selected ? "#7f7f7f3d" : "#7f7f7f24"))
        .frame({ maxWidth: "infinity" })
        .onTap(() => cmux("workspace.select", { workspace_id: w().id }))
  )
)
