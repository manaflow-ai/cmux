// ── Design Cockpit sidebar ──────────────────────────────────────────────
// A product designer's pinned design-system + pipeline control panel.
// Authored as a single SwiftUI-style view expression.

let palette = [
  ["name": "Brand / Indigo",   "hex": "#4F46E5"],
  ["name": "Brand / Violet",   "hex": "#7C3AED"],
  ["name": "Accent / Amber",   "hex": "#F59E0B"],
  ["name": "Success / Green",  "hex": "#10B981"],
  ["name": "Danger / Red",     "hex": "#EF4444"],
  ["name": "Ink / 900",        "hex": "#0B1020"],
  ["name": "Surface / 50",     "hex": "#F8FAFC"]
]

// Most recent exports my optimizer watcher dropped into ./exports.
let recentAssets = [
  ["file": "hero-light@2x.png",   "kind": "PNG",  "size": "284 KB", "icon": "photo"],
  ["file": "hero-dark@2x.png",    "kind": "PNG",  "size": "291 KB", "icon": "photo"],
  ["file": "logo-mark.svg",       "kind": "SVG",  "size": "4 KB",   "icon": "scribble.variable"],
  ["file": "app-icon-1024.png",   "kind": "PNG",  "size": "118 KB", "icon": "app.badge"],
  ["file": "social-card.webp",    "kind": "WEBP", "size": "62 KB",  "icon": "rectangle.on.rectangle"]
]

// Tokens emitted by my token build (tokens.json -> Style Dictionary).
let spacing = [
  ["t": "space.1", "v": "4"],
  ["t": "space.2", "v": "8"],
  ["t": "space.3", "v": "12"],
  ["t": "space.4", "v": "16"],
  ["t": "space.6", "v": "24"],
  ["t": "space.8", "v": "32"]
]
let radii = [
  ["t": "radius.sm", "v": "6"],
  ["t": "radius.md", "v": "10"],
  ["t": "radius.lg", "v": "16"],
  ["t": "radius.pill", "v": "999"]
]
let typeScale = [
  ["t": "text.caption", "v": "12 / 16"],
  ["t": "text.body",    "v": "14 / 20"],
  ["t": "text.title",   "v": "20 / 28"],
  ["t": "text.display", "v": "32 / 40"]
]

HSplitView(spacing: 0) {

  // ───────── LEFT: live cmux pipeline ─────────
  VStack(alignment: .leading, spacing: 14) {

    HStack(spacing: 8) {
      Image(systemName: "paintpalette.fill").foregroundColor("#7C3AED")
      Text("Design Cockpit").font(.headline).bold()
      Spacer()
      Text("\(workspaceCount)").font(.caption).foregroundColor("#64748B")
    }

    Text("WORKSPACES").font(.caption).fontWeight(.semibold).foregroundColor("#94A3B8")

    ForEach(workspaces) { ws in
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          // Selected workspace gets a filled dot, others hollow.
          if ws.selected {
            Image(systemName: "largecircle.fill.circle").foregroundColor("#4F46E5")
          } else {
            Image(systemName: "circle").foregroundColor("#CBD5E1")
          }
          Text(ws.title)
            .fontWeight(.semibold)
            .foregroundColor(ws.selected ? "#0B1020" : "#475569") // ternary -> missing
          Spacer()
          Text("\(ws.tabs.count) tabs").font(.caption).foregroundColor("#94A3B8")
        }
        .padding(6)
        .background(                                              // .background -> missing
          RoundedRectangle(cornerRadius: 8)
            .fill(ws.selected ? Color(hex: "#EEF2FF") : Color.clear)
        )
        .onTapGesture { cmux("workspace.select", workspace_id: ws.id) }

        // Tabs of the selected workspace, tappable to focus the surface.
        if ws.selected {
          ForEach(ws.tabs) { tab in
            HStack(spacing: 8) {
              Image(systemName: tab.focused ? "play.fill" : "terminal")
                .foregroundColor(tab.focused ? "#10B981" : "#94A3B8")
              Text(tab.title)
                .font(.caption)
                .foregroundColor(tab.focused ? "#0B1020" : "#64748B")
              Spacer()
            }
            .padding(.leading, 24)                                // edge-specific padding -> missing
            .onTapGesture { cmux("surface.focus", surface_id: tab.id) }
          }
        }
      }
    }

    Spacer()

    Divider()
    Button(action: { cmux("workspace.create", template: "design-export") }) {
      HStack(spacing: 6) {
        Image(systemName: "plus.square.dashed").foregroundColor("#4F46E5")
        Text("New export workspace").font(.caption).fontWeight(.semibold)
      }
    }
  }
  .padding(14)

  // ───────── RIGHT: the design system at a glance ─────────
  VStack(alignment: .leading, spacing: 16) {

    // Palette: tap a swatch to copy its hex.
    Text("PALETTE").font(.caption).fontWeight(.semibold).foregroundColor("#94A3B8")
    VStack(alignment: .leading, spacing: 8) {
      ForEach(palette) { c in
        HStack(spacing: 10) {
          // The swatch itself. No shapes/fills in the subset, so I fake the
          // chip by tinting a filled SF Symbol with the token's own hex.
          Image(systemName: "square.fill").foregroundColor(c["hex"])
          VStack(alignment: .leading, spacing: 0) {
            Text(c["name"]).font(.caption).fontWeight(.semibold).foregroundColor("#0B1020")
            Text(c["hex"]).font(.caption).foregroundColor("#64748B")
          }
          Spacer()
          Image(systemName: "doc.on.clipboard").foregroundColor("#CBD5E1")
        }
        .onTapGesture { cmux("clipboard.write", text: c["hex"]) } // clipboard verb -> missing
      }
    }

    Divider()

    // Recent exports. Real thumbnails would be Image(file:) previews.
    Text("RECENT EXPORTS").font(.caption).fontWeight(.semibold).foregroundColor("#94A3B8")
    VStack(alignment: .leading, spacing: 8) {
      ForEach(recentAssets) { a in
        HStack(spacing: 10) {
          AsyncImage(url: URL(fileURLWithPath: "exports/\(a["file"])")) { img in
            img.resizable().scaledToFill()
          } placeholder: {
            Image(systemName: a["icon"]).foregroundColor("#7C3AED")
          }
          .frame(width: 36, height: 36)                          // thumbnail sizing -> missing
          .cornerRadius(6)                                       // -> missing
          VStack(alignment: .leading, spacing: 0) {
            Text(a["file"]).font(.caption).fontWeight(.semibold).foregroundColor("#0B1020")
            Text("\(a["kind"]) · \(a["size"])").font(.caption).foregroundColor("#94A3B8")
          }
          Spacer()
        }
        .onTapGesture { cmux("file.reveal", path: "exports/\(a["file"])") }
      }
    }

    Divider()

    // Live design tokens. Three tappable token groups.
    Text("TOKENS").font(.caption).fontWeight(.semibold).foregroundColor("#94A3B8")

    Text("Spacing").font(.caption).fontWeight(.semibold).foregroundColor("#475569")
    ForEach(spacing) { s in
      HStack(spacing: 8) {
        Text(s["t"]).font(.caption).foregroundColor("#0B1020")
        Spacer()
        Text("\(s["v"])px").font(.caption).fontWeight(.semibold).foregroundColor("#4F46E5")
      }
      .onTapGesture { cmux("clipboard.write", text: s["v"]) }
    }

    Text("Radius").font(.caption).fontWeight(.semibold).foregroundColor("#475569")
    ForEach(radii) { r in
      HStack(spacing: 8) {
        Text(r["t"]).font(.caption).foregroundColor("#0B1020")
        Spacer()
        Text("\(r["v"])px").font(.caption).fontWeight(.semibold).foregroundColor("#7C3AED")
      }
    }

    Text("Type scale").font(.caption).fontWeight(.semibold).foregroundColor("#475569")
    ForEach(typeScale) { t in
      HStack(spacing: 8) {
        Text(t["t"]).font(.caption).foregroundColor("#0B1020")
        Spacer()
        Text(t["v"]).font(.caption).fontWeight(.semibold).foregroundColor("#10B981")
      }
    }

    Spacer()

    Divider()
    Button(action: { cmux("surface.run", command: "npm run tokens:build") }) {
      HStack(spacing: 6) {
        Image(systemName: "arrow.triangle.2.circlepath").foregroundColor("#10B981")
        Text("Rebuild tokens").font(.caption).fontWeight(.semibold)
      }
    }
  }
  .padding(14)
}
