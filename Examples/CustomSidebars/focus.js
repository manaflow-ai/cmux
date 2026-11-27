// Focus: the selected workspace, front and center, then whatever needs you.
// Minimal zen sidebar showing off the reactive JS lane: signals, hover, taps.
//   cp Examples/CustomSidebars/focus.js ~/.config/cmux/sidebars/ && cmux sidebar open focus

const unreadRows = () =>
  (data.workspaces() ?? []).filter((w) => w.unread > 0 && !w.selected);

sidebar(() =>
  VStack({ spacing: 10 }, [
    VStack({ spacing: 2 }, [
      Text("NOW").font(10).weight("semibold").color("tertiary"),
      Text(() => data.selectedTitle() || "No workspace")
        .font(16).weight("semibold").lineLimit(2),
    ])
      .paddingHorizontal(10).paddingVertical(8)
      .cornerRadius(10)
      .background("#7f7f7f24")
      .frame({ maxWidth: "infinity" }),
    Text(() => (unreadRows().length > 0 ? "NEEDS YOU" : "ALL CLEAR"))
      .font(10).weight("semibold").color("tertiary").paddingHorizontal(10),
    ForEach(
      { items: unreadRows, key: (w) => w.id },
      (w) =>
        HStack({ spacing: 8 }, [
          Text(() => w().title).font(13).lineLimit(1).truncation("tail").color("secondary"),
          Spacer(),
          Text(() => String(w().unread))
            .font("caption2").bold().color("white")
            .paddingHorizontal(5).paddingVertical(1)
            .background("#E4573D").cornerRadius(7),
        ])
          .paddingHorizontal(10).paddingVertical(6)
          .cornerRadius(8)
          .hoverBackground("#7f7f7f24")
          .frame({ maxWidth: "infinity" })
          .onTap(() => cmux("workspace.select", { workspace_id: w().id }))
    ),
  ]),
  { surface: "glass" }
)
