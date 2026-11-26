// Design-system showcase sidebar: a dense Grid of shapes filled from a hex palette,
// stress-testing composition depth (overlays, backgrounds, masks, rotation, shadows).
// Lightly bound to real workspace data so swatch counts/labels reflect live state.

func palette() -> [String] {
  return [
    "#FF5470", "#FF8C42", "#FFD23F", "#3BCEAC",
    "#0EAD69", "#2EC4B6", "#4D96FF", "#6C5CE7",
    "#A06CD5", "#EE6C4D", "#118AB2", "#073B4C"
  ]
}

func shadeName(_ i: Int) -> String {
  let names = ["Rose", "Amber", "Sun", "Mint", "Pine", "Teal", "Sky", "Iris", "Violet", "Ember", "Ocean", "Slate"]
  return names[i % names.count]
}

// View helper: one labeled swatch cell, composing a base shape with overlays + shadow.
func swatch(_ hex: String, _ kind: Int, _ label: String, _ angle: Double) -> some View {
  ZStack {
    RoundedRectangle(cornerRadius: 14)
      .foregroundStyle("#161B22")
      .overlay(alignment: .topTrailing) {
        Circle()
          .foregroundStyle(hex)
          .frame(width: 8, height: 8)
          .opacity(0.7)
          .offset(x: -6, y: 6)
      }

    VStack {
      ZStack {
        Circle()
          .foregroundStyle(hex)
          .frame(width: 48, height: 48)
          .blur(radius: 9)
          .opacity(0.55)

        Group {
          if kind == 0 {
            Circle().foregroundStyle(hex)
          } else if kind == 1 {
            Capsule().foregroundStyle(hex)
          } else if kind == 2 {
            Ellipse().foregroundStyle(hex)
          } else {
            RoundedRectangle(cornerRadius: 8).foregroundStyle(hex)
          }
        }
        .frame(width: 38, height: 38)
        .shadow(radius: 6, x: 0, y: 3, color: hex)
        .rotationEffect(.degrees(angle))
        .overlay(alignment: .center) {
          Circle()
            .foregroundStyle("#FFFFFF")
            .frame(width: 9, height: 9)
            .opacity(0.85)
            .offset(x: -7, y: -7)
            .blur(radius: 1)
        }
      }
      .frame(width: 52, height: 52)

      Label(label, systemImage: "paintpalette.fill")
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)

      Text(hex)
        .font(.system(size: 8, design: .monospaced))
        .foregroundStyle(hex)
        .textCase(.uppercase)
    }
    .padding(8)
  }
  .frame(height: 96)
  .help("\(label) — \(hex)")
  .contextMenu {
    Button("Apply \(hex)") { cmux("noop", value: hex) }
    Button("Copy name") { cmux("noop", value: label) }
  }
}

ScrollView {
  VStack(alignment: .leading) {

    // ── Header band: gradient-ish stack of capsules masking a title ──
    ZStack {
      HStack {
        ForEach(palette().indices) { i in
          Rectangle()
            .foregroundStyle(palette()[i])
            .frame(maxWidth: .infinity)
        }
      }
      .frame(height: 56)
      .cornerRadius(16)
      .opacity(0.9)
      .mask {
        RoundedRectangle(cornerRadius: 16)
      }

      VStack(alignment: .leading) {
        Text("DESIGN SYSTEM")
          .font(.system(size: 15, design: .default))
          .bold()
          .foregroundStyle("#FFFFFF")
          .shadow(radius: 4, x: 0, y: 1, color: "#000000")
        Text("\(palette().count) tokens · \(workspaceCount) live cells")
          .font(.caption)
          .foregroundStyle("#FFFFFF")
          .opacity(0.85)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .overlay(alignment: .topTrailing) {
      Image(systemName: "sparkles")
        .imageScale(.large)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle("#FFFFFF")
        .padding(10)
    }
    .padding(.bottom, 4)

    // ── Live gauge strip driven by real unread/workspace data ──
    HStack {
      ZStack {
        Circle()
          .foregroundStyle("#161B22")
        Circle()
          .foregroundStyle("#0EAD69")
          .opacity(0.25)
        Text("\(workspaceCount)")
          .font(.system(size: 16))
          .bold()
          .foregroundStyle("#3BCEAC")
      }
      .frame(width: 46, height: 46)
      .overlay(alignment: .bottomTrailing) {
        Circle()
          .foregroundStyle(unreadTotal > 0 ? "#FF5470" : "#0EAD69")
          .frame(width: 12, height: 12)
          .offset(x: 2, y: 2)
      }

      VStack(alignment: .leading) {
        Text(selectedTitle)
          .font(.caption)
          .bold()
          .lineLimit(1)
          .truncationMode(.tail)
        Gauge(value: Double(min(unreadTotal, 20)), total: 20.0) {
          Text("unread")
        }
        .tint("#FF8C42")
        Text("\(unreadTotal) unread · \(clock.time)")
          .font(.system(size: 9, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(10)
    .background("#0D1117")
    .cornerRadius(12)
    .padding(.bottom, 6)

    // ── The shape grid: 3 columns of palette swatches ──
    Text("PALETTE GRID")
      .font(.caption)
      .fontWeight(.semibold)
      .foregroundStyle(.tertiary)
      .textCase(.uppercase)

    Grid {
      ForEach(Array(palette().enumerated()), id: \.offset) { i, hex in
        // emit a new row every 3 cells using a guard on i % 3
        if i % 3 == 0 {
          GridRow {
            ForEach((i ..< min(i + 3, palette().count))) { j in
              swatch(palette()[j], j % 4, shadeName(j), Double(j * 30 - 60))
            }
          }
        }
      }
    }

    Divider()
      .padding(.vertical, 6)

    // ── Rotation showcase: a fan of rotated capsules under one ZStack ──
    Text("ROTATION FAN")
      .font(.caption)
      .fontWeight(.semibold)
      .foregroundStyle(.tertiary)
      .textCase(.uppercase)

    ZStack {
      ForEach(palette().indices) { i in
        Capsule()
          .foregroundStyle(palette()[i])
          .frame(width: 10, height: 70)
          .opacity(0.85)
          .shadow(radius: 3, x: 0, y: 1, color: palette()[i])
          .rotationEffect(.degrees(Double(i) * 30.0))
      }
      Circle()
        .foregroundStyle("#0D1117")
        .frame(width: 26, height: 26)
        .overlay(alignment: .center) {
          Image(systemName: "circle.hexagongrid.fill")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle("#FFD23F")
        }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 150)
    .background("#0D1117")
    .cornerRadius(14)
    .padding(.bottom, 6)

    // ── Shape primitives row: each canonical shape demoed once ──
    Text("PRIMITIVES")
      .font(.caption)
      .fontWeight(.semibold)
      .foregroundStyle(.tertiary)
      .textCase(.uppercase)

    ScrollView(.horizontal) {
      HStack {
        VStack {
          Circle().foregroundStyle("#FF5470").frame(width: 34, height: 34)
          Text("Circle").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
        }
        VStack {
          Capsule().foregroundStyle("#4D96FF").frame(width: 50, height: 26)
          Text("Capsule").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
        }
        VStack {
          Ellipse().foregroundStyle("#3BCEAC").frame(width: 50, height: 30)
          Text("Ellipse").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
        }
        VStack {
          RoundedRectangle(cornerRadius: 10).foregroundStyle("#FFD23F").frame(width: 38, height: 34)
          Text("RoundRect").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
        }
        VStack {
          UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 16, bottomTrailingRadius: 2, topTrailingRadius: 16)
            .foregroundStyle("#A06CD5").frame(width: 38, height: 34)
          Text("Uneven").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
        }
        VStack {
          Rectangle().foregroundStyle("#EE6C4D").frame(width: 38, height: 34)
          Text("Rect").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
        }
      }
      .padding(10)
    }
    .scrollIndicators(.hidden)
    .background("#0D1117")
    .cornerRadius(12)

    Divider()
      .padding(.vertical, 6)

    // ── Shadow + blur ladder ──
    Text("ELEVATION")
      .font(.caption)
      .fontWeight(.semibold)
      .foregroundStyle(.tertiary)
      .textCase(.uppercase)

    HStack {
      ForEach((0 ..< 5)) { e in
        RoundedRectangle(cornerRadius: 10)
          .foregroundStyle(palette()[e * 2])
          .frame(maxWidth: .infinity)
          .frame(height: 44)
          .shadow(radius: Double(e * 3), x: 0, y: Double(e + 1), color: "#000000")
          .overlay(alignment: .center) {
            Text("\(e)")
              .font(.system(size: 10, design: .monospaced))
              .bold()
              .foregroundStyle("#FFFFFF")
          }
      }
    }
    .padding(.bottom, 4)

    // ── Tint scale via opacity on one hue ──
    Text("OPACITY SCALE")
      .font(.caption)
      .fontWeight(.semibold)
      .foregroundStyle(.tertiary)
      .textCase(.uppercase)

    HStack {
      ForEach((1 ..< 9)) { s in
        Capsule()
          .foregroundStyle("#6C5CE7")
          .frame(maxWidth: .infinity)
          .frame(height: 28)
          .opacity(Double(s) / 8.0)
      }
    }
    .padding(.bottom, 4)

    // ── Menu of palette actions ──
    Menu("Palette actions") {
      ForEach(Array(palette().prefix(4).enumerated()), id: \.offset) { i, hex in
        Button("Set accent \(shadeName(i))") { cmux("noop", value: hex) }
      }
      Button("Reset") { cmux("noop", value: "reset") }
    }
    .padding(.top, 4)

    Text("Composed from \(palette().count) tokens · live at \(clock.time)")
      .font(.system(size: 9, design: .monospaced))
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.top, 6)
  }
  .padding(12)
}
.scrollIndicators(.hidden)
.background("#010409")