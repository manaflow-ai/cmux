// panel-info: right-sidebar demo. Everything about the SELECTED workspace:
// branch, directory, listening ports (click to open), PRs, activity.
//   cp Examples/CustomSidebars/panel-info.js ~/.config/cmux/sidebars/
//   cmux right-sidebar set custom panel-info

const ws = () => (data.workspaces() ?? []).find((w) => w.selected) ?? null;

function labeled(label, valueFn) {
  return HStack({ spacing: 6, alignment: "top" }, [
    Text(label).font(10).weight("semibold").color("tertiary")
      .frame({ width: 52, alignment: "leading" }),
    Text(valueFn).font(12).lineLimit(2).truncation("middle").color("secondary"),
  ]).frame({ maxWidth: "infinity" });
}

sidebar(() =>
  VStack({ spacing: 10 }, [
    // Header: workspace title + unread badge.
    HStack({ spacing: 8 }, [
      Text(() => ws()?.title ?? "No workspace")
        .font(15).weight("semibold").lineLimit(2),
      Spacer(),
      Text(() => (ws()?.unread > 0 ? String(ws().unread) : ""))
        .font("caption2").bold().color("white")
        .paddingHorizontal(() => (ws()?.unread > 0 ? 5 : 0))
        .paddingVertical(() => (ws()?.unread > 0 ? 1 : 0))
        .background(() => (ws()?.unread > 0 ? "#E4573D" : null))
        .cornerRadius(7),
    ])
      .paddingHorizontal(10).paddingVertical(8)
      .cornerRadius(10)
      .background("#7f7f7f24")
      .frame({ maxWidth: "infinity" }),

    // Facts.
    VStack({ spacing: 6 }, [
      labeled("BRANCH", () =>
        ws()?.branch ? ws().branch + (ws().dirty ? " ●" : "") : "—"),
      labeled("DIR", () => ws()?.directory || "—"),
      labeled("TABS", () => String(ws()?.tabCount ?? 0)),
    ]).paddingHorizontal(10),

    // Ports: one button per listening port, click opens localhost.
    VStack({ spacing: 4 }, [
      Text("PORTS").font(10).weight("semibold").color("tertiary").paddingHorizontal(10),
      ForEach(
        { items: () => ws()?.ports ?? [], key: (p) => String(p) },
        (p) =>
          HStack({ spacing: 6 }, [
            Circle({ size: 6 }).fill("#34C759"),
            Text(() => "localhost:" + p()).font(12).monospaced(),
            Spacer(),
            Image("arrow.up.right").font(9).color("tertiary"),
          ])
            .paddingHorizontal(10).paddingVertical(5)
            .cornerRadius(7)
            .hoverBackground("#7f7f7f24")
            .frame({ maxWidth: "infinity" })
            .onTap(() => openURL("http://localhost:" + p()))
      ),
      Text(() => ((ws()?.ports ?? []).length === 0 ? "none listening" : ""))
        .font(11).color("tertiary").paddingHorizontal(10),
    ]),

    // Pull requests.
    VStack({ spacing: 4 }, [
      Text("PULL REQUESTS").font(10).weight("semibold").color("tertiary").paddingHorizontal(10),
      ForEach(
        { items: () => ws()?.prs ?? [], key: (u) => String(u) },
        (u) =>
          HStack({ spacing: 6 }, [
            Image("arrow.triangle.pull").font(10).color("tertiary"),
            Text(() => String(u()).replace(/^https:\/\/github\.com\//, ""))
              .font(11).lineLimit(1).truncation("middle").color("secondary"),
          ])
            .paddingHorizontal(10).paddingVertical(5)
            .cornerRadius(7)
            .hoverBackground("#7f7f7f24")
            .frame({ maxWidth: "infinity" })
            .onTap(() => openURL(String(u()))),
      ),
      Text(() => ((ws()?.prs ?? []).length === 0 ? "none open" : ""))
        .font(11).color("tertiary").paddingHorizontal(10),
    ]),

    // Latest agent/conversation activity.
    VStack({ spacing: 4 }, [
      Text("LATEST").font(10).weight("semibold").color("tertiary"),
      Text(() => ws()?.latestMessage || "quiet")
        .font(11).color("secondary").lineLimit(4),
    ])
      .paddingHorizontal(10).paddingVertical(8)
      .cornerRadius(10)
      .background("#7f7f7f14")
      .frame({ maxWidth: "infinity" }),
    Spacer(),
  ]).paddingHorizontal(6),
  { surface: "glass" }
)
