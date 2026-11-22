#if DEBUG && os(iOS)
import CmuxMobileDesign
import SwiftUI

// Disposable mocks for the key row debate (branch on hold, never merged).
// Leo, 2026-11-22: "just debate this for a while, hold and present".
//
// The problem: the Claude / Codex / Ollama launchers type a command and press
// Return with no confirmation, 4 pt right of the → arrow. Three answers, drawn
// statically in `TerminalKeyBarGallery` (nothing here is wired to the
// terminal; production and the default layout are unchanged):
//
// - A, "keys only": the row without launchers; they move to the composer's
//   + menu, under "Run…".
// - B, "safe launchers" (recommended): arrows first, launchers at the end of
//   the row after a hairline, tinted with a `›_` glyph; 44 pt hit shapes,
//   6 pt apart; the keyboard toggle at the trailing edge.
// - C, "context decides": a 36 pt chip strip, above the row (C1), in place of
//   the scroller (C2) or inside an empty composer (C3); a tapped chip arms to
//   "Run ⏎" and runs only on a second tap.

/// One mock key: what the gallery draws for each design.
enum KeyRowMockKey: Hashable {
    case text(String)
    case icon(String)
    case launcher(String)

    var isGlyph: Bool {
        switch self {
        case .icon: true
        case .text(let label): label.count == 1
        case .launcher: false
        }
    }
}

/// The production row's keys, as labels, in classic's groups.
enum KeyRowMockKeys {
    static let modifiers: [KeyRowMockKey] = [
        .text("⌃"), .text("⌥"), .text("⌘"), .text("⇧"), .icon("doc.on.clipboard"), .text("Tab"), .text("Esc"),
    ]
    static let arrows: [KeyRowMockKey] = [.text("↑"), .text("↓"), .text("←"), .text("→")]
    static let chords: [KeyRowMockKey] = [.text("⏎"), .text("^C"), .text("^D")]
    static let tail: [KeyRowMockKey] = [
        .text("Clear"), .text("~"), .text("$"), .text("/"), .text("@"), .text("|"), .text("^Z"),
        .text("Home"), .text("End"), .text("PgUp"), .text("PgDn"),
    ]
    static let launchers: [KeyRowMockKey] = [.launcher("Claude"), .launcher("Codex"), .launcher("Ollama")]
    static let zoomAndHide: [KeyRowMockKey] = [
        .icon("minus.magnifyingglass"), .icon("plus.magnifyingglass"), .icon("chevron.down.square"),
    ]
    static let agents = ["Claude", "Codex", "Ollama"]
}

/// The launchers' tint: they run a command, so they never look like a plain key.
private let launcherTint = Color.orange

/// A mock key cap: production's 28 pt glass cap, radius 8; a glyph key is 32 pt wide.
struct KeyRowMockCap: View {
    let key: KeyRowMockKey
    /// Draws the 44 pt hit shape around the cap as a faint outline (B).
    var hitShape = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: KeyRowGlass.cornerRadius, style: .continuous)
        cap
            .frame(minWidth: TerminalDockMetrics.minKeyWidth, maxWidth: key.isGlyph ? TerminalDockMetrics.minKeyWidth : nil,
                   minHeight: TerminalDockMetrics.keyRowHeight, maxHeight: TerminalDockMetrics.keyRowHeight)
            .glassEffect(tinted ? .regular.tint(launcherTint.opacity(0.55)) : .regular, in: shape)
            .frame(minWidth: hitShape ? 44 : nil, minHeight: hitShape ? 44 : nil)
            .overlay {
                if hitShape {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                }
            }
    }

    private var tinted: Bool {
        if case .launcher = key { true } else { false }
    }

    @ViewBuilder private var cap: some View {
        switch key {
        case .icon(let symbol):
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
        case .text(let label):
            Text(label).font(.system(size: 14, weight: .medium)).lineLimit(1).padding(.horizontal, 6)
        case .launcher(let name):
            HStack(spacing: 4) {
                Text("›_").font(.system(size: 12, weight: .bold, design: .monospaced))
                Text(name).font(.system(size: 14, weight: .medium))
            }
            .lineLimit(1)
            .padding(.horizontal, 7)
        }
    }
}

/// The pinned joystick, as a static circle.
struct KeyRowMockJoystick: View {
    var body: some View {
        Circle()
            .fill(Color.white.opacity(0.08))
            .overlay(Circle().fill(Color.white.opacity(0.7)).frame(width: 8, height: 8))
            .frame(width: TerminalDockMetrics.keyRowHeight, height: TerminalDockMetrics.keyRowHeight)
            .glassEffect(.regular, in: Circle())
    }
}

/// A hairline between key groups.
struct KeyRowMockHairline: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.3)).frame(width: 0.5, height: 20)
    }
}

/// A mock row: pinned leading keys, a scroller, optional pinned trailing keys.
struct KeyRowMockRow<Leading: View, Scroller: View, Trailing: View>: View {
    var spacing: CGFloat = TerminalDockMetrics.keySpacing
    var anchor: UnitPoint = .leading
    @ViewBuilder var leading: Leading
    @ViewBuilder var scroller: Scroller
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: spacing) {
            HStack(spacing: 6) { leading }
            ScrollView(.horizontal) {
                HStack(spacing: spacing) { scroller }
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(anchor)
            HStack(spacing: 6) { trailing }
        }
        .padding(.horizontal, TerminalDockMetrics.horizontalInset)
    }
}

/// Draws `content` at its natural width, scaled down to fit the available width.
struct KeyRowMockScaledToFit<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var natural = CGSize(width: 1, height: 1)
    @State private var available: CGFloat = 1

    var body: some View {
        let scale = min(1, available / max(1, natural.width))
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: natural.height * scale)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
            .overlay(alignment: .topLeading) {
                content
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { natural = $0 }
                    .scaleEffect(scale, anchor: .topLeading)
            }
            .clipped()
            .allowsHitTesting(false)
    }
}

/// A mock's caption and note.
struct KeyRowMockSection<Content: View>: View {
    let id: String
    let title: String
    let note: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text(note).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            content
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keyRowMock.\(id)")
    }
}

// MARK: - A, keys only

struct KeyRowMockA: View {
    private var keys: [KeyRowMockKey] {
        KeyRowMockKeys.modifiers + KeyRowMockKeys.chords + KeyRowMockKeys.arrows
            + KeyRowMockKeys.tail + KeyRowMockKeys.zoomAndHide
    }

    var body: some View {
        KeyRowMockSection(id: "A", title: "Mock A: keys only",
                          note: "No launchers in the row. They move to the composer's + menu under \"Run…\".") {
            KeyRowMockRow {
                KeyRowMockCap(key: .icon("keyboard"))
                KeyRowMockJoystick()
                KeyRowMockCap(key: .icon("character.textbox"))
            } scroller: {
                // visible-only: a fixed mock row of at most 30 static keys (DEBUG gallery)
                ForEach(Array(keys.enumerated()), id: \.offset) { KeyRowMockCap(key: $0.element) }
            } trailing: {
                EmptyView()
            }
            HStack(alignment: .bottom, spacing: 10) {
                composer
                menu
            }
            .padding(.horizontal, 12)
        }
    }

    private var composer: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .glassEffect(.regular.tint(Color.white.opacity(0.15)), in: Circle())
            Text("Message").font(.system(size: 15)).foregroundStyle(.white.opacity(0.4))
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(width: 150)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: TerminalDockMetrics.fieldCornerRadius, style: .continuous))
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuRow("photo", "Photo", nil)
            menuRow("doc", "File", nil)
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 6)
            Text("Run…").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            menuRow("terminal", "Claude", "claude --dangerously-skip-permissions")
            menuRow("terminal", "Codex", "codex --yolo …")
            menuRow("terminal", "Ollama", "ollama run ")
        }
        .frame(width: 200)
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func menuRow(_ symbol: String, _ title: String, _ subtitle: String?) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15)).foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

// MARK: - B, safe launchers

struct KeyRowMockB: View {
    private var terminalKeys: [KeyRowMockKey] {
        KeyRowMockKeys.arrows + KeyRowMockKeys.modifiers + KeyRowMockKeys.chords + KeyRowMockKeys.tail
    }

    var body: some View {
        KeyRowMockSection(id: "B", title: "Mock B: safe launchers (recommended)",
                          note: "Arrows first. Launchers last, after a hairline, tinted with ›_. Every key has a 44 pt hit shape (dashed), 6 pt apart. Keyboard toggle at the trailing edge. At rest, scrolled to the end, then the whole row.") {
            row(anchor: .leading)
            row(anchor: .trailing)
            KeyRowMockScaledToFit { row(anchor: .leading, scrolls: false) }
        }
    }

    @ViewBuilder
    private func row(anchor: UnitPoint, scrolls: Bool = true) -> some View {
        let leading = Group {
            KeyRowMockJoystick().frame(width: 44, height: 44)
            KeyRowMockCap(key: .icon("character.textbox"), hitShape: true)
        }
        let trailing = KeyRowMockCap(key: .icon("keyboard"), hitShape: true)
        if scrolls {
            KeyRowMockRow(spacing: 6, anchor: anchor) { leading } scroller: { scroller } trailing: { trailing }
        } else {
            HStack(spacing: 6) {
                leading
                scroller
                trailing
            }.padding(.horizontal, TerminalDockMetrics.horizontalInset)
        }
    }

    @ViewBuilder private var scroller: some View {
        // visible-only: a fixed mock row of at most 30 static keys (DEBUG gallery)
        ForEach(Array(terminalKeys.enumerated()), id: \.offset) { KeyRowMockCap(key: $0.element, hitShape: true) }
        KeyRowMockHairline()
        // visible-only: a fixed mock row of at most 30 static keys (DEBUG gallery)
        ForEach(KeyRowMockKeys.launchers, id: \.self) { KeyRowMockCap(key: $0, hitShape: true) }
        // visible-only: a fixed mock row of at most 30 static keys (DEBUG gallery)
        ForEach(KeyRowMockKeys.zoomAndHide, id: \.self) { KeyRowMockCap(key: $0, hitShape: true) }
    }
}

// MARK: - C, context decides

/// A 36 pt agent chip; armed, it reads "Run ⏎" and runs on the next tap.
struct KeyRowMockChip: View {
    let name: String
    var armed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 5) {
            Text("›_").font(.system(size: 12, weight: .bold, design: .monospaced))
            Text(name).font(.system(size: 14, weight: .medium))
            if armed {
                Text("Run ⏎").font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .lineLimit(1)
        .foregroundStyle(armed ? Color.cmuxMobileOnAccent : .primary)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .glassEffect(armed ? .regular.tint(Color.cmuxMobileAccent) : .regular.tint(launcherTint.opacity(0.3)), in: shape)
    }
}

struct KeyRowMockChipStrip: View {
    var armed: String?

    var body: some View {
        HStack(spacing: 8) {
            // visible-only: a fixed mock row of at most 30 static keys (DEBUG gallery)
            ForEach(KeyRowMockKeys.agents, id: \.self) { KeyRowMockChip(name: $0, armed: $0 == armed) }
        }
    }
}

/// The plain key row the C variants sit with (arrows first, no launchers).
struct KeyRowMockPlainRow: View {
    private var keys: [KeyRowMockKey] {
        KeyRowMockKeys.modifiers + KeyRowMockKeys.chords + KeyRowMockKeys.arrows + KeyRowMockKeys.tail + KeyRowMockKeys.zoomAndHide
    }

    var body: some View {
        KeyRowMockRow {
            KeyRowMockCap(key: .icon("keyboard"))
            KeyRowMockJoystick()
            KeyRowMockCap(key: .icon("character.textbox"))
        } scroller: {
            // visible-only: a fixed mock row of at most 30 static keys (DEBUG gallery)
            ForEach(Array(keys.enumerated()), id: \.offset) { KeyRowMockCap(key: $0.element) }
        } trailing: {
            EmptyView()
        }
    }
}

struct KeyRowMockC: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            KeyRowMockSection(id: "C1", title: "Mock C1: chips above the key row",
                              note: "At an empty shell prompt a 36 pt chip strip rises above the row; it leaves when an agent runs.") {
                KeyRowMockChipStrip().padding(.horizontal, 12)
                KeyRowMockPlainRow()
            }
            KeyRowMockSection(id: "C2", title: "Mock C2: chips in place of the scroller",
                              note: "At an empty prompt the chips replace the scroller; any key press brings the keys back.") {
                HStack(spacing: 6) {
                    KeyRowMockCap(key: .icon("keyboard"))
                    KeyRowMockJoystick()
                    KeyRowMockCap(key: .icon("character.textbox"))
                    KeyRowMockHairline().padding(.horizontal, 2)
                    KeyRowMockChipStrip()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
            }
            KeyRowMockSection(id: "C3", title: "Mock C3: chips inside an empty composer",
                              note: "The empty composer field offers the chips; typing hides them.") {
                VStack(alignment: .leading, spacing: 8) {
                    KeyRowMockChipStrip()
                    Text("Message").font(.system(size: 15)).foregroundStyle(.white.opacity(0.4)).padding(.leading, 4)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: TerminalDockMetrics.fieldCornerRadius, style: .continuous))
                .padding(.horizontal, 12)
                KeyRowMockPlainRow()
            }
            KeyRowMockSection(id: "C.run", title: "Mock C: an armed chip",
                              note: "First tap arms the chip (Run ⏎); the second tap runs it. Tapping elsewhere disarms it.") {
                KeyRowMockChipStrip(armed: "Claude").padding(.horizontal, 12)
            }
        }
    }
}

/// Every debate mock, for `TerminalKeyBarGallery`.
struct KeyRowDebateMocks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Key row debate mocks (on hold)")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
            KeyRowMockA()
            KeyRowMockB()
            KeyRowMockC()
        }
    }
}
#endif
