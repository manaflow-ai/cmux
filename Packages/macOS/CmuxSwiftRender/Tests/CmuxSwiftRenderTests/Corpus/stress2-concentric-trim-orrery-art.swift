// Pure-composition art piece: concentric stroked Circles with .trim arcs over
// Angular/Radial gradient fields, rotated, shadowed, and ZStack-blended.
// Minimal data binding — clock seconds/minutes/hours and workspaceCount/unreadTotal
// only drive the trim fractions and orbital angles. Everything else is composition.

// ── Palette ──────────────────────────────────────────────────────────────────
func ink() -> String { return "#05060B" }

func spectrum() -> [String] {
  return ["#FF4D6D", "#FF8C42", "#FFD23F", "#3BCEAC",
          "#2EC4B6", "#4D96FF", "#6C5CE7", "#A06CD5"]
}

// Hue for an orbital index, walking the spectrum.
func hue(_ i: Int) -> String {
  let s = spectrum()
  return s[((i % s.count) + s.count) % s.count]
}

// Fraction in 0...1 from a value over a span (clamped, safe /0).
func frac(_ v: Double, _ span: Double) -> Double {
  let d = span == 0 ? 1.0 : span
  return min(1.0, max(0.0, v / d))
}

// Named arc role → a (trim-fraction, hue, ring lineWidth) tuple, expressed as a
// switch over a role string so each concentric ring stays declarative.
func ringWidth(_ role: String) -> Double {
  switch role {
  case "second": return 3.0
  case "minute": return 5.0
  case "hour":   return 7.0
  default:       return 2.0
  }
}

func ringHue(_ role: String) -> String {
  switch role {
  case "second": return "#3BCEAC"
  case "minute": return "#4D96FF"
  case "hour":   return "#FF4D6D"
  default:       return "#6C5CE7"
  }
}

// One concentric trimmed ring. base track + bright arc + a glowing cap dot,
// all rotated so the arc head points at the live value. Shape modifiers
// (.trim/.stroke) apply on the concrete Circle before erasure.
func ring(_ diameter: Double, _ role: String, _ value: Double) -> some View {
  let w = ringWidth(role)
  let h = ringHue(role)
  ZStack {
    // dim full-circle track
    Circle()
      .stroke("#161B22", lineWidth: w)
      .frame(width: diameter, height: diameter)

    // bright progress arc, started at 12 o'clock via -90° rotation
    Circle()
      .trim(from: 0.0, to: value)
      .stroke(h, lineWidth: w)
      .frame(width: diameter, height: diameter)
      .rotationEffect(.degrees(-90))
      .shadow(color: h, radius: 5, x: 0, y: 0)
      .overlay(alignment: .center) {
        // a thin inner echo arc, half the value, opposite spin
        Circle()
          .trim(from: 0.0, to: value / 2.0)
          .stroke(h, lineWidth: 1)
          .frame(width: diameter - w * 2.0 - 4.0, height: diameter - w * 2.0 - 4.0)
          .rotationEffect(.degrees(90))
          .opacity(0.55)
      }
  }
}

// One orbiting body: a glowing dot placed on its orbit by offset, then the whole
// thing rotated around center. Composition only; index drives hue + angle.
func orbiter(_ i: Int, _ count: Int, _ radius: Double, _ spin: Double) -> some View {
  let h = hue(i)
  let step = count == 0 ? 360.0 : 360.0 / Double(count)
  ZStack {
    Circle()
      .fill(h)
      .frame(width: 10, height: 10)
      .shadow(color: h, radius: 6, x: 0, y: 0)
      .overlay(alignment: .center) {
        Circle().fill("#FFFFFF").frame(width: 3, height: 3).opacity(0.9)
      }
      .offset(y: -radius)
  }
  .rotationEffect(.degrees(Double(i) * step + spin))
}

// ── Root: a vertical stack of self-contained art panels ───────────────────────
ScrollView {
  VStack(alignment: .leading) {

    // ── Panel I — Orrery: concentric trim chronometer over an angular field ──
    ZStack {
      // angular gradient sweep as the deep background of the dial
      AngularGradient(colors: spectrum(), startPoint: .center, endPoint: .center)
        .opacity(0.20)
        .frame(width: 220, height: 220)
        .clipShape(Circle())
        .blur(radius: 14)
        .rotationEffect(.degrees(Double(clock.second) * 6.0))

      // radial nebula core
      RadialGradient(colors: ["#4D96FF", "#05060B"], startPoint: .center, endPoint: .bottom)
        .frame(width: 150, height: 150)
        .clipShape(Circle())
        .opacity(0.7)

      // concentric live rings: seconds / minutes / hours
      ring(200, "second", frac(Double(clock.second), 60.0))
      ring(170, "minute", frac(Double(clock.minute), 60.0))
      ring(140, "hour", frac(Double(clock.hour % 12), 12.0))

      // a stroked-only mid ring decorated as ticks via a rotated capsule fan
      ZStack {
        ForEach((0 ..< 12)) { t in
          Capsule()
            .fill("#2A3140")
            .frame(width: 2, height: 8)
            .offset(y: -64)
            .rotationEffect(.degrees(Double(t) * 30.0))
        }
      }

      // center readout
      VStack {
        Text(clock.time)
          .font(.system(size: 22, design: .monospaced))
          .bold()
          .monospacedDigit()
          .foregroundStyle("#FFFFFF")
          .shadow(color: "#000000", radius: 4, x: 0, y: 1)
        Text(clock.weekday)
          .font(.system(size: 9, design: .monospaced))
          .textCase(.uppercase)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 240)
    .background {
      RadialGradient(colors: ["#0D1117", "#05060B"], startPoint: .center, endPoint: .bottom)
    }
    .cornerRadius(20)
    .overlay(alignment: .topLeading) {
      Text("ORRERY")
        .font(.system(size: 9, design: .monospaced))
        .fontWeight(.semibold)
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .padding(10)
    }
    .padding(.bottom, 10)

    // ── Panel II — Orbital system: data-light, count drives the body fan ──
    ZStack {
      // faint orbit guide rings
      ForEach((1 ..< 4)) { r in
        Circle()
          .stroke("#161B22", lineWidth: 1)
          .frame(width: Double(r) * 50.0, height: Double(r) * 50.0)
          .opacity(0.8)
      }

      // central star: layered radial glow + bright core
      ZStack {
        Circle()
          .fill("#FFD23F")
          .frame(width: 30, height: 30)
          .blur(radius: 9)
          .opacity(0.8)
        Circle()
          .fill("#FFE680")
          .frame(width: 16, height: 16)
          .shadow(color: "#FFD23F", radius: 8, x: 0, y: 0)
      }

      // orbiting bodies — count tied to live workspaces, never invented data
      ForEach((0 ..< max(1, min(8, workspaceCount)))) { i in
        orbiter(i, max(1, min(8, workspaceCount)), 75.0, Double(clock.second) * 3.0)
      }

      // an unread "comet": only present when there is unread activity
      if unreadTotal > 0 {
        Capsule()
          .fill("#FF4D6D")
          .frame(width: 4, height: 26)
          .opacity(0.85)
          .shadow(color: "#FF4D6D", radius: 6, x: 0, y: 0)
          .offset(y: -100)
          .rotationEffect(.degrees(Double(clock.second) * 6.0 + 45.0))
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 200)
    .background {
      AngularGradient(colors: ["#05060B", "#0D1117", "#101826", "#05060B"], startPoint: .center, endPoint: .center)
    }
    .cornerRadius(20)
    .overlay(alignment: .topLeading) {
      Text("\(min(8, workspaceCount)) BODIES")
        .font(.system(size: 9, design: .monospaced))
        .fontWeight(.semibold)
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .padding(10)
    }
    .padding(.bottom, 10)

    // ── Panel III — Spectrum arc fan: every hue as a trimmed wedge ──────────
    ZStack {
      ForEach(Array(spectrum().enumerated()), id: \.offset) { i, hex in
        Circle()
          .trim(from: 0.0, to: 0.11)
          .stroke(hex, lineWidth: 9)
          .frame(width: 150, height: 150)
          .shadow(color: hex, radius: 3, x: 0, y: 0)
          .rotationEffect(.degrees(Double(i) * (360.0 / Double(spectrum().count)) - 90.0))
          .opacity(0.92)
      }
      // masked gradient disc peeking through the wedge gaps
      AngularGradient(colors: spectrum(), startPoint: .center, endPoint: .center)
        .frame(width: 96, height: 96)
        .clipShape(Circle())
        .mask {
          Circle()
        }
        .opacity(0.85)
        .rotationEffect(.degrees(Double(clock.second) * -4.0))
        .overlay(alignment: .center) {
          Image(systemName: "circle.hexagongrid.fill")
            .imageScale(.large)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle("#FFFFFF")
            .opacity(0.9)
        }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 190)
    .background {
      RadialGradient(colors: ["#101826", "#05060B"], startPoint: .center, endPoint: .bottom)
    }
    .cornerRadius(20)
    .overlay(alignment: .topLeading) {
      Text("\(spectrum().count) HUES")
        .font(.system(size: 9, design: .monospaced))
        .fontWeight(.semibold)
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .padding(10)
    }
    .padding(.bottom, 10)

    // ── Panel IV — Lissajous-ish ellipse weave: scaled/rotated ellipses ──────
    ZStack {
      ForEach((0 ..< 6)) { k in
        Ellipse()
          .stroke(hue(k), lineWidth: 1.5)
          .frame(width: 150, height: 60)
          .rotationEffect(.degrees(Double(k) * 30.0))
          .opacity(0.7)
          .scaleEffect(1.0 - Double(k) * 0.05)
      }
      Ellipse()
        .fill("#6C5CE7")
        .frame(width: 26, height: 26)
        .blur(radius: 6)
        .opacity(0.7)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 170)
    .background("#05060B")
    .cornerRadius(20)
    .overlay(alignment: .topLeading) {
      Text("WEAVE")
        .font(.system(size: 9, design: .monospaced))
        .fontWeight(.semibold)
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .padding(10)
    }
    .padding(.bottom, 10)

    // ── Footer caption ──────────────────────────────────────────────────────
    Text("Composed of pure shapes · live at \(clock.time)")
      .font(.system(size: 9, design: .monospaced))
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.top, 2)
  }
  .padding(14)
}
.scrollIndicators(.hidden)
.background(ink())