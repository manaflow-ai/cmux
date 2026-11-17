public import AppKit
public import CmuxNextDesign

/// Stage 0's stand-in Home (``HomeLaunchBare``): the window's first frame as the real Home draws a
/// fresh Chief's page (``HomeLaunchBareLayout``: sidebar, list, header with the empty avatar disc
/// and the Chief's name, the message box at the bottom), drawn with AppKit and the plan's colors
/// only (`LaunchShellLook`: no theme, settings or services). Its box is the first responder and
/// keeps everything: Return sends (held in order), Shift- or Option-Return is a new line, as the
/// real box. Every click lands here; one outside the box gives the box the keyboard back.
public final class HomeLaunchBareView: NSView {
    private let layout: HomeLaunchBareLayout
    private let field = HomeLaunchBareField(frame: .zero)
    private let scroll = NSScrollView()
    private let fieldBack = NSView()
    private let placeholder: NSTextField
    private let pill: NSTextField
    private let pillBack = NSView()
    private let avatar = NSView()
    /// The sends made in the box, in order (``parked``).
    public private(set) var sends: [String] = []

    /// - Parameters:
    ///   - frame: The window's content bounds.
    ///   - look: The plan's background, bar color and appearance.
    ///   - title: The Chief's name.
    ///   - placeholder: The box's placeholder ("Message").
    ///   - mark: Launch marks around the text setup (`home.bare.text_start`, `home.bare.text_ready`).
    public init(frame: CGRect, look: LaunchShellLook, title: String, placeholder text: String, mark: (String) -> Void) {
        layout = HomeLaunchBareLayout(bounds: CGRect(origin: .zero, size: frame.size))
        mark("home.bare.text_start")
        let font = NSFont.systemFont(ofSize: TypeScale.Base.body)  // the real box's 13 pt (MessagesLab Fixture.bodyFont), unscaled
        let (placeholder, name) = (NSTextField(labelWithString: text), NSTextField(labelWithString: title))
        name.font = .boldSystemFont(ofSize: TypeScale.Base.body)
        placeholder.font = font
        (self.placeholder, pill) = (placeholder, name)
        super.init(frame: frame)
        field.font = font
        mark("home.bare.text_ready")
        appearance = NSAppearance(named: look.dark ? .darkAqua : .aqua)
        wantsLayer = true
        layer?.backgroundColor = look.background.cgColor
        addBand(layout.sidebar, look.bar)
        addBand(layout.list, look.background)
        addBand(layout.divider, .separatorColor)
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 18
        avatar.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        avatar.frame = layout.avatar
        addSubview(avatar)
        let width = pill.intrinsicContentSize.width + 28
        pillBack.wantsLayer = true
        pillBack.layer?.cornerRadius = 14
        pillBack.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        pillBack.frame = layout.pill(width: width)
        addSubview(pillBack)
        pill.alignment = .center
        pill.frame = pillBack.frame.insetBy(dx: 14, dy: (28 - pill.intrinsicContentSize.height) / 2)
        addSubview(pill)
        makeBox(font: font)
        mark("home.bare.view_ready")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    nonisolated public override var isFlipped: Bool { true }

    /// What the box holds now: its text, its selection and its sends.
    public var parked: HomeLaunchBareParked {
        HomeLaunchBareParked(text: field.string, selection: field.selectedRange(), sends: sends)
    }

    public override func viewDidMoveToWindow() {  // stage 0 is key: its box takes the keys
        super.viewDidMoveToWindow()
        FocusRoute(.system, "stage 0's stand-in Home: its message box takes the launch's keys").moveKeyboard(in: window, to: field)
    }

    public override func mouseDown(with event: NSEvent) { FocusRoute(.person, "a click in stage 0's stand-in Home").moveKeyboard(in: window, to: field) }

    private func addBand(_ rect: CGRect, _ color: NSColor) {
        let band = NSView(frame: rect)
        band.wantsLayer = true
        band.layer?.backgroundColor = color.cgColor
        addSubview(band)
    }

    private func makeBox(font: NSFont) {
        fieldBack.wantsLayer = true
        fieldBack.layer?.cornerRadius = 15
        fieldBack.layer?.borderWidth = 0.5
        fieldBack.layer?.borderColor = NSColor.separatorColor.cgColor
        // No fill: the real box is glass over the page, so the stand-in draws only its outline.
        addSubview(fieldBack)
        field.isRichText = false
        field.allowsUndo = true  // undo-safe: replaceAllTextUndoably (code only clears the box at a send, through it)
        field.drawsBackground = false
        field.textContainerInset = NSSize(width: 0, height: 7)
        field.textContainer?.lineFragmentPadding = 0
        field.isVerticallyResizable = true
        field.isHorizontallyResizable = false
        field.autoresizingMask = [.width]
        field.textContainer?.widthTracksTextView = true
        field.onSend = { [weak self] in self?.send() }
        field.onChange = { [weak self] in self?.layoutBox() }
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.documentView = field
        addSubview(scroll)
        placeholder.textColor = .placeholderTextColor
        addSubview(placeholder)
        layoutBox()
    }

    /// The box at its text's height, growing up from the bottom as the real one does.
    private func layoutBox() {
        let lines = max(1, field.string.components(separatedBy: "\n").count)
        let box = layout.field(lines: lines)
        fieldBack.frame = box
        let text = box.insetBy(dx: 12, dy: 0)
        scroll.frame = text
        field.frame.size.width = text.width
        field.minSize = NSSize(width: text.width, height: text.height)
        placeholder.isHidden = !field.string.isEmpty
        placeholder.frame = CGRect(x: text.minX, y: text.minY + (HomeLaunchBareLayout.oneLine - placeholder.intrinsicContentSize.height) / 2,
                                   width: text.width, height: placeholder.intrinsicContentSize.height)
    }

    private func send() {
        let text = field.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sends.append(text)
        field.replaceAllTextUndoably("")  // undo-safe: replaceAllTextUndoably (a send clears the box; Cmd-Z brings it back)
        layoutBox()
    }
}

/// The stand-in box's text view: Return (or keypad Enter) sends, Shift- or Option-Return inserts a
/// new line, and Return while composing marked text (an input method) goes to it, as `FieldTextView`.
final class HomeLaunchBareField: NSTextView {
    var onSend: () -> Void = {}
    var onChange: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 36 || event.keyCode == 76, !hasMarkedText() else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) || flags.contains(.option) {
            insertNewlineIgnoringFieldEditor(nil)
        } else {
            onSend()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        onChange()
    }
}
