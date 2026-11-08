// Dev server board: every workspace with listening ports, port pills, jump on
// tap. Shows reactive filtering and per-row context menus in the JS lane.
//   cp Examples/CustomSidebars/ports.js ~/.config/cmux/sidebars/ && cmux sidebar open ports

const serving = () => (data.workspaces() ?? []).filter((w) => (w.ports ?? []).length > 0);

sidebar(() =>
  VStack({ spacing: 6 }, [
    HStack({ spacing: 6 }, [
      Text("Servers").font("headline"),
      Spacer(),
      Text(() => String(serving().length)).font("caption").secondary().monospaced(),
    ]).paddingHorizontal(10),
    Divider(),
    ForEach(
      { items: serving, key: (w) => w.id },
      (w) =>
        VStack({ spacing: 4 }, [
          Text(() => w().title)
            .font(13).lineLimit(1).truncation("tail")
            .color(() => (w().selected ? "primary" : "secondary")),
          HStack({ spacing: 4 }, [
            ForEach(
              { items: () => (w().ports ?? []).map((p) => ({ id: p })), key: (p) => p.id },
              (p) =>
                Text(() => ":" + p().id)
                  .font("caption2").monospaced().color("teal")
                  .paddingHorizontal(5).paddingVertical(1)
                  .background("#00808026").cornerRadius(5)
                  .onTap(() => openURL("http://localhost:" + p().id))
            ),
            Spacer(),
          ]),
        ])
          .paddingHorizontal(10).paddingVertical(6)
          .cornerRadius(8)
          .background(() => (w().selected ? "#7f7f7f3d" : null))
          .hoverBackground(() => (w().selected ? "#7f7f7f3d" : "#7f7f7f24"))
          .frame({ maxWidth: "infinity" })
          .onTap(() => cmux("workspace.select", { workspace_id: w().id }))
    ),
    Text(() => (serving().length === 0 ? "No listening ports" : ""))
      .font("caption").color("tertiary").paddingHorizontal(10),
  ]),
  { surface: "glass" }
)
