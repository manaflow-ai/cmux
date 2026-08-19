// Reactive workspace sidebar for the cmux JS scene runtime.
//
// The program runs once. Every function-valued prop is a live binding: it
// re-evaluates only when the data it reads changes, and only that node
// updates. Rows keep stable identity by workspace id, so the drag-to-reorder
// gesture and animations survive live data updates mid-drag.
//
// Install:  cp Examples/CustomSidebars/workspaces.js ~/.config/cmux/sidebars/
// Open:     cmux sidebar open workspaces

sidebar(() =>
  VStack({ spacing: 6 }, [
    HStack({ spacing: 6 }, [
      Text("Workspaces").font("headline"),
      Spacer(),
      Text(() => String(data.workspaceCount() ?? 0))
        .font("caption").secondary().monospaced(),
    ]),
    Divider(),
    Reorderable(
      {
        items: () => data.workspaces() ?? [],
        key: (w) => w.id,
        onMove: (id, index) =>
          cmux("workspace.reorder", { workspace_id: id, index: index }),
      },
      (w) =>
        HStack({ spacing: 8 }, [
          Circle({ size: 7 })
            .fill(() => (w().selected ? "accent" : "#00000000"))
            .stroke(() => (w().selected ? "accent" : "tertiary")),
          VStack({ spacing: 1 }, [
            Text(() => w().title).font(13).lineLimit(1),
            Text(() => {
              const ws = w();
              const branch = ws.branch ? ws.branch + (ws.dirty ? " *" : "") : "";
              const ports = (ws.ports || []).map((p) => ":" + p).join(" ");
              return [branch, ports].filter(Boolean).join("  ") || " ";
            })
              .font("caption").secondary().lineLimit(1).monospaced(),
          ]),
          Spacer(),
          Text(() => (w().unread > 0 ? String(w().unread) : ""))
            .font("caption2").color("white").bold()
            .padding(3)
            .background(() => (w().unread > 0 ? "red" : null))
            .cornerRadius(8),
        ])
          .padding(6)
          .cornerRadius(6)
          .background(() => (w().selected ? "#7f7f7f26" : null))
          .frame({ maxWidth: "infinity" })
          .onTap(() => cmux("workspace.select", { workspace_id: w().id }))
    ),
    Spacer({ minLength: 8 }),
    Text(() => (data.clock() ? data.clock().time : ""))
      .font("caption2").secondary().monospaced(),
  ])
)
