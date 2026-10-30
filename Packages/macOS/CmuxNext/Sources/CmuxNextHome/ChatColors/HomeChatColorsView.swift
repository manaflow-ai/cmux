import AppKit
import CmuxHomeRender
import CmuxNextDesign

/// Chat Colors…: one chat's bubble and text colours, with a live preview. Each change is stored
/// at once (the open chat redraws as you pick); Automatic text is picked to read on the bubble.
/// AppKit (plans/cmux-next/no-swiftui-DESIGN.md): the view follows the store and the design
/// settings through Observation and updates its controls in place, so a colour well stays
/// attached to the colour panel while you drag.
@MainActor
final class HomeChatColorsView: NSView {
    private let store: HomeChatColorStore
    private let conversation: String
    /// The colours the chat draws with for a choice (its bubble style, the default for every chat, then the choice),
    /// called in this view's theme scope.
    private let resolve: (HomeBubbleColors) -> HomeChatColorsPreview
    private let onDone: () -> Void

    private let preview = HomeChatColorsPreviewView()
    private var sections: [Section] = []
    private let resetButton = NSButton()
    private let doneButton = NSButton()

    private var colors: HomeBubbleColors { store.colors(for: conversation) }

    /// One "My Messages" or "Their Messages" block: its bubble row and its text row.
    private struct Section {
        let fill: Row
        let text: Row
        let shown: KeyPath<HomeChatColorsPreview, HomeChatColorsPreview.Pair>
    }

    /// A row of swatches and a colour well for one role.
    private struct Row {
        let key: WritableKeyPath<HomeBubbleColors, HomeColor?>
        let swatches: [HomeChatColorSwatch]
        let well: HomeChatColorWell
        let current: KeyPath<HomeChatColorsPreview.Pair, NSColor>
    }

    static let width: CGFloat = 340

    init(store: HomeChatColorStore, conversation: String, resolve: @escaping (HomeBubbleColors) -> HomeChatColorsPreview,
         onDone: @escaping () -> Void) {
        self.store = store
        self.conversation = conversation
        self.resolve = resolve
        self.onDone = onDone
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
        build()
        follow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout

    private func build() {
        let mine = makeSection(HomeChatColorsStrings.mine, fill: \.sent, text: \.sentText, swatches: Self.sentSwatches, shown: \.sent)
        let theirs = makeSection(HomeChatColorsStrings.theirs, fill: \.received, text: \.receivedText,
                                 swatches: Self.receivedSwatches, shown: \.received)
        sections = [mine.section, theirs.section]

        resetButton.title = HomeChatColorsStrings.reset
        resetButton.bezelStyle = .push
        resetButton.target = self
        resetButton.action = #selector(reset)

        doneButton.attributedTitle = Self.doneTitle(hint: .return)
        doneButton.bezelStyle = .push
        doneButton.keyEquivalent = CmuxDialogKeyHint.return.keyEquivalent
        doneButton.keyEquivalentModifierMask = CmuxDialogKeyHint.return.modifierMask
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.setAccessibilityLabel(HomeChatColorsStrings.done)
        doneButton.setAccessibilityHelp(CmuxDialogKeyHint.return.spokenName)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [resetButton, spacer, doneButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [preview, mine.view, theirs.view, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for full in [preview, buttons] {
            full.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    private func makeSection(_ title: String, fill: WritableKeyPath<HomeBubbleColors, HomeColor?>,
                             text: WritableKeyPath<HomeBubbleColors, HomeColor?>, swatches: [HomeColor],
                             shown: KeyPath<HomeChatColorsPreview, HomeChatColorsPreview.Pair>) -> (view: NSView, section: Section) {
        let heading = NSTextField(labelWithString: title)
        heading.font = NSFont.preferredFont(forTextStyle: .headline)
        let fillRow = makeRow(HomeChatColorsStrings.bubble, key: fill, choices: swatches, auto: false, current: \.fill)
        let textRow = makeRow(HomeChatColorsStrings.text, key: text, choices: [.gray255(255), .gray255(0)], auto: true, current: \.text)
        let stack = NSStackView(views: [heading, fillRow.view, textRow.view])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return (stack, Section(fill: fillRow.row, text: textRow.row, shown: shown))
    }

    private func makeRow(_ label: String, key: WritableKeyPath<HomeBubbleColors, HomeColor?>, choices: [HomeColor], auto: Bool,
                         current: KeyPath<HomeChatColorsPreview.Pair, NSColor>) -> (view: NSView, row: Row) {
        let name = NSTextField(labelWithString: label)
        name.textColor = .secondaryLabelColor
        name.widthAnchor.constraint(equalToConstant: 48).isActive = true
        // nil first: Default (a bubble) or Automatic (text).
        let swatches = ([nil] as [HomeColor?] + choices.map(Optional.some)).map { color -> HomeChatColorSwatch in
            let swatch = HomeChatColorSwatch(color: color, auto: color == nil && auto)
            swatch.onPick = { [weak self] in self?.pick(color, for: key) }
            return swatch
        }
        let well = HomeChatColorWell()
        well.onPick = { [weak self] picked in self?.pick(HomeColor(picked), for: key) }
        let stack = NSStackView(views: [name] + swatches + [well])
        stack.orientation = .horizontal
        stack.spacing = 6
        return (stack, Row(key: key, swatches: swatches, well: well, current: current))
    }

    // MARK: - State

    /// Shows the store's colours for this chat, again whenever they or the design settings change.
    /// Stops when the view is gone (the panel showed another chat): the re-arm holds it weakly.
    private func follow() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.follow() }
        }
    }

    private func update() {
        let colors = colors
        let shown = performWithTheme { resolve(colors) }
        preview.show(shown)
        for section in sections {
            for row in [section.fill, section.text] {
                for swatch in row.swatches { swatch.isSelected = colors[keyPath: row.key] == swatch.color }
                row.well.show(colors[keyPath: row.key]?.nsColor ?? shown[keyPath: section.shown][keyPath: row.current])
            }
        }
        resetButton.isEnabled = !colors.isEmpty
    }

    // The theme the preview resolves in comes from the window and the appearance.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }

    private func pick(_ color: HomeColor?, for key: WritableKeyPath<HomeBubbleColors, HomeColor?>) {
        var next = colors
        next[keyPath: key] = color
        store.set(next, for: conversation)
    }

    @objc private func reset() { store.set(HomeBubbleColors(), for: conversation) }
    @objc private func done() { onDone() }

    /// "Done ↩": the title, then the key that presses it in the secondary ink (as `CmuxDialogActionButton` draws it).
    private static func doneTitle(hint: CmuxDialogKeyHint) -> NSAttributedString {
        let title = NSMutableAttributedString(string: HomeChatColorsStrings.done, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        title.append(NSAttributedString(string: " " + hint.glyph, attributes: [
            .font: Typography.caption, .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return title
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
