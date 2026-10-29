import AppKit
import CmuxHomeRender
import CmuxNextDesign
import SwiftUI

/// Chat Colors…: one chat's bubble and text colours, with a live preview. Each change is stored
/// at once (the open chat redraws as you pick); Automatic text is picked to read on the bubble.
struct HomeChatColorsView: View {
    let store: HomeChatColorStore
    let conversation: String
    /// The colours the chat draws with for a choice (its bubble style, the default for every chat, then the choice).
    let resolve: (HomeBubbleColors) -> HomeChatColorsPreview
    let onDone: () -> Void

    private var colors: HomeBubbleColors { store.colors(for: conversation) }

    var body: some View {
        let shown = resolve(colors)
        VStack(alignment: .leading, spacing: 14) {
            preview(shown)
            section(HomeChatColorsStrings.mine, fill: \.sent, text: \.sentText, swatches: Self.sentSwatches, shown: shown.sent)
            section(HomeChatColorsStrings.theirs, fill: \.received, text: \.receivedText, swatches: Self.receivedSwatches, shown: shown.received)
            HStack {
                Button(HomeChatColorsStrings.reset) { store.set(HomeBubbleColors(), for: conversation) }
                    .disabled(colors.isEmpty)
                Spacer()
                CmuxDialogActionButton(HomeChatColorsStrings.done, hint: .return, action: onDone)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func preview(_ shown: HomeChatColorsPreview) -> some View {
        VStack(spacing: 6) {
            HStack {
                bubble(HomeChatColorsStrings.sampleReceived, shown.received)
                Spacer(minLength: 40)
            }
            HStack {
                Spacer(minLength: 40)
                bubble(HomeChatColorsStrings.sampleSent, shown.sent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: shown.background)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(HomeChatColorsStrings.previewLabel)
    }

    private func bubble(_ text: String, _ pair: HomeChatColorsPreview.Pair) -> some View {
        Text(text)
            .font(.system(size: TypeScale.body))
            .foregroundStyle(Color(nsColor: pair.text))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(Color(nsColor: pair.fill)))
    }

    private func section(_ title: String, fill: WritableKeyPath<HomeBubbleColors, HomeColor?>, text: WritableKeyPath<HomeBubbleColors, HomeColor?>,
                         swatches: [HomeColor], shown: HomeChatColorsPreview.Pair) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            row(HomeChatColorsStrings.bubble) {
                swatch(nil, selected: colors[keyPath: fill] == nil, auto: false, key: fill)
                ForEach(swatches, id: \.self) { color in
                    swatch(color, selected: colors[keyPath: fill] == color, auto: false, key: fill)
                }
                picker(fill, current: shown.fill)
            }
            row(HomeChatColorsStrings.text) {
                swatch(nil, selected: colors[keyPath: text] == nil, auto: true, key: text)
                ForEach([HomeColor.gray255(255), HomeColor.gray255(0)], id: \.self) { color in
                    swatch(color, selected: colors[keyPath: text] == color, auto: false, key: text)
                }
                picker(text, current: shown.text)
            }
        }
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            content()
        }
    }

    /// A swatch; nil is Default (a bubble) or Automatic (text), drawn as a slashed circle.
    private func swatch(_ color: HomeColor?, selected: Bool, auto: Bool, key: WritableKeyPath<HomeBubbleColors, HomeColor?>) -> some View {
        Button {
            var next = colors
            next[keyPath: key] = color
            store.set(next, for: conversation)
        } label: {
            ZStack {
                if let color {
                    Circle().fill(Color(nsColor: color.nsColor))
                    Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                } else {
                    Circle().strokeBorder(Color.secondary, lineWidth: 1)
                    Image(systemName: auto ? "textformat" : "circle.slash").font(.system(size: TypeScale.caption)).foregroundStyle(.secondary)
                }
                if selected { Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3) }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(color?.hex ?? (auto ? HomeChatColorsStrings.automatic : HomeChatColorsStrings.styleDefault))
        .accessibilityLabel(color?.hex ?? (auto ? HomeChatColorsStrings.automatic : HomeChatColorsStrings.styleDefault))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Any colour (the system colour panel), starting from the one shown.
    private func picker(_ key: WritableKeyPath<HomeBubbleColors, HomeColor?>, current: NSColor) -> some View {
        ColorPicker(HomeChatColorsStrings.custom, selection: Binding(
            get: { Color(nsColor: colors[keyPath: key]?.nsColor ?? current) },
            set: { picked in
                var next = colors
                next[keyPath: key] = HomeColor(NSColor(picked))
                store.set(next, for: conversation)
            }), supportsOpacity: false)
        .labelsHidden()
        .help(HomeChatColorsStrings.custom)
    }

    /// Messages' blue first, then the colours Messages and the system use most.
    static let sentSwatches: [HomeColor] = ["#0A84FF", "#34C759", "#AF52DE", "#FF2D55", "#FF9500", "#FFD60A", "#30B0C7", "#8E8E93"]
        .compactMap(HomeColor.init(hex:))
    static let receivedSwatches: [HomeColor] = ["#E9E9EB", "#3B3B3D", "#D6EAFF", "#D9F7E0", "#EADCF8", "#FFE5CC", "#1C2A4A"]
        .compactMap(HomeColor.init(hex:))
}

/// The colours a choice draws with, for the preview and the pickers' starting colour.
struct HomeChatColorsPreview {
    struct Pair {
        let fill: NSColor
        let text: NSColor
    }

    let background: NSColor
    let sent: Pair
    let received: Pair

    init(_ palette: HomePalette) {
        let page = palette.background
        background = HomeColor(red: page.red, green: page.green, blue: page.blue).nsColor
        sent = Pair(fill: (palette.outgoingGradient.first?.color ?? palette.caret).nsColor, text: palette.outgoingText.nsColor)
        received = Pair(fill: palette.incomingBubble.nsColor, text: palette.incomingText.nsColor)
    }
}

extension HomeColor {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    /// The sRGB colour of `color` (opaque).
    init(_ color: NSColor) {
        let s = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        self.init(red: s.redComponent, green: s.greenComponent, blue: s.blueComponent)
    }
}
