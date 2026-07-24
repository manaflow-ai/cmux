import CMUXMobileCore
import CmuxMobileTerminalKit
import Foundation
import UIKit

/// The iOS terminal's keyboard input surface.
///
/// This is a **documentless responder**, not a text editor. It conforms to
/// ``UIKeyInput`` and ``UITextInput`` directly on a bare `UIView` (the same
/// construction iSH's `TerminalView` and vvterm's IME proxy ship) instead of
/// subclassing `UITextView`. Every committed character is forwarded to the
/// remote Mac and nothing is echoed locally, so there is no editable buffer to
/// keep in sync — the view owns only a transient IME ``markedText`` string plus
/// a zero-width *delete-repeat anchor* (see ``usesDeleteRepeatAnchor``).
///
/// ## Why not a `UITextView`
///
/// A `UITextView` (or any real-document field) drives backspace auto-repeat and
/// dictation off its internal text storage and selection, not off
/// ``UIKeyInput/hasText``. The previous implementation forced `hasText` to
/// `true` but kept clearing its document to `""`, so with an empty document and
/// a collapsed selection at offset 0 the framework had nothing to repeat-delete
/// and never consulted the overridden `hasText` for repeat — the on-device
/// evidence (a held Backspace fires `deleteBackward()` zero times) is exactly
/// this. Dictation broke the same way: its placeholder was nuked mid-flight.
///
/// A bare ``UIKeyInput``/``UITextInput`` responder with no document has neither
/// problem. The framework honors ``hasText`` for repeat on a raw responder, the
/// view presents vvterm's toggling one-character zero-width document so UIKit's
/// modern document-driven repeat path also keeps firing, and the explicit
/// dictation-placeholder methods on a real (non-cleared) `UITextInput` conformer
/// let recognized text arrive through ``insertText(_:)`` as one block.
///
/// Autocorrect/predictive text stay **disabled** here and fundamentally cannot
/// be enabled: they require the field to retain the in-progress word, which is
/// incompatible with forwarding every keystroke to a remote terminal.
final class TerminalInputTextView: UIView, UIKeyInput, UITextInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onEscapeSequence: ((Data) -> Void)?
    /// Invoked when the Paste accessory button reads an image off the system
    /// clipboard. The host forwards the bytes (+ a lowercase format hint) to the
    /// Mac, which injects the resulting file path into the terminal. Clipboard
    /// *text* does not use this path; it rides ``onText``.
    var onPasteImage: ((Data, String) -> Void)?
    var onZoom: ((TerminalFontZoomDirection) -> Void)?
    var onHideKeyboard: (() -> Void)?
    /// Fired by the trailing "customize" button so the SwiftUI host can present
    /// the toolbar shortcuts editor.
    var onOpenToolbarSettings: (() -> Void)?
    /// Fired by the Files accessory button when terminal artifacts are supported.
    /// The source view lets the host anchor an inline popover to the tapped control.
    var onOpenArtifactFiles: ((UIView) -> Void)?
    /// Invoked when the composer accessory button is tapped. The host toggles
    /// the iMessage-style composer above the terminal.
    var onToggleComposer: (() -> Void)?
    /// Fired by the pinned HIDE button: temporarily hides the toolbar + composer
    /// until the next terminal tap.
    var onHideChrome: (() -> Void)?
    var artifactFilesEnabled = false {
        didSet {
            guard oldValue != artifactFilesEnabled, accessoryStackView != nil else { return }
            populateAccessoryActions()
            terminalAccessoryToolbar.setNeedsLayout()
            terminalAccessoryToolbar.layoutIfNeeded()
        }
    }
    var accessoryLayoutInsetsProvider: (() -> UIEdgeInsets)?
    /// The leftmost toolbar button. Toggles its glyph between dismiss-keyboard
    /// (when the keyboard is up) and show-keyboard (when down) via
    /// ``setKeyboardShown(_:)``.
    private weak var dismissButton: UIButton?
    /// The composer toggle, pinned in the container (not the scrollable stack) so
    /// it is always reachable regardless of the button row's scroll position.
    private weak var composerButton: UIButton?
    private weak var accessoryArrowNub: TerminalArrowNubView?
    /// The armed/sticky modifier state machine, extracted into the testable
    /// ``TerminalInputModifierState`` reducer. This view is now a dumb
    /// first-responder that forwards taps into the reducer and reads its state
    /// back for byte encoding and button styling.
    private var modifierState = TerminalInputModifierState()
    private var controlAccessoryArmed: Bool { modifierState.isArmed(.control) }
    private var alternateAccessoryArmed: Bool { modifierState.isArmed(.alternate) }
    private var commandAccessoryArmed: Bool { modifierState.isArmed(.command) }
    private var shiftAccessoryArmed: Bool { modifierState.isArmed(.shift) }
    private var controlAccessorySticky: Bool { modifierState.isStickyOn(.control) }
    private var alternateAccessorySticky: Bool { modifierState.isStickyOn(.alternate) }
    private var commandAccessorySticky: Bool { modifierState.isStickyOn(.command) }
    private var shiftAccessorySticky: Bool { modifierState.isStickyOn(.shift) }

    /// The in-progress IME composition string, or `nil` when not composing.
    ///
    /// This is the view's only *committed* text state. While an IME (CJK,
    /// emoji-via-IME) is composing, UIKit calls
    /// ``setMarkedText(_:selectedRange:)`` with the candidate; the view holds it
    /// here so ``markedTextRange`` reports active composition and ``text(in:)``
    /// can answer the framework's read-back. On ``unmarkText()`` the held string
    /// commits through ``insertText(_:)`` and this clears. There is no
    /// committed-document buffer.
    private var markedText: String?

    /// Toggles the zero-width character used for the delete-repeat anchor on each
    /// empty-buffer ``deleteBackward()``. Alternating between two distinct
    /// zero-width characters guarantees the virtual document's *contents* change
    /// every delete, which (alongside the `inputDelegate` text-change brackets)
    /// re-arms UIKit's document-driven backspace repeat. Borrowed verbatim from
    /// vvterm's `deleteRepeatAnchorUsesAlternate`.
    private var deleteRepeatAnchorUsesAlternate = false

    /// Monotonic-ish tap timestamp for the reducer's double-tap window. Uses
    /// the same wall-clock source the legacy `Date()` comparisons used, so the
    /// 0.4s sticky promotion behaves identically.
    private static func tapNow() -> TimeInterval { Date().timeIntervalSinceReferenceDate }

    /// The framework-supplied delegate that wants to know about marked/selection
    /// changes. Required by the ``UITextInput`` conformance; the view notifies it
    /// around ``setMarkedText(_:selectedRange:)`` and around each empty-buffer
    /// delete (the anchor re-arm) so the keyboard's composition and repeat
    /// machinery stay synchronized.
    weak var inputDelegate: (any UITextInputDelegate)?

    /// Word/sentence tokenizer required by ``UITextInput``. The view has no real
    /// document to tokenize, but the protocol mandates a non-nil tokenizer; the
    /// default string tokenizer satisfies it without ever being meaningfully
    /// queried.
    lazy var tokenizer: any UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    override var canBecomeFirstResponder: Bool { true }

    /// Conforming to ``UITextInput`` would otherwise make this an accessibility
    /// element, which would shadow the real terminal surface's accessibility
    /// content. The view is an invisible input proxy, so keep it out of the
    /// accessibility tree (the surface carries the rendered-text label). iSH does
    /// the same for the same reason.
    override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    override var keyCommands: [UIKeyCommand]? {
        guard markedText == nil else { return nil }
        var commands = TerminalHardwareKeyResolver.makeKeyCommands(
            target: self,
            action: #selector(handleHardwareKeyCommand(_:))
        )
        // A bare UIView does not inherit UITextView's Cmd+V, so wire it
        // explicitly to the same clipboard routing as the toolbar Paste button.
        commands.append(UIKeyCommand(input: "v", modifierFlags: [.command], action: #selector(paste(_:))))
        return commands
    }

    /// Restores standard system paste on this documentless responder.
    ///
    /// As a `UITextView` the view inherited `paste(_:)`/`canPerformAction(_:)`;
    /// as a bare `UIView` it must re-expose them so hardware Cmd+V and the
    /// edit-menu Paste keep working. Only paste is advertised — copy/cut/select
    /// are meaningless on a proxy that holds no document, so they stay disabled
    /// rather than surfacing a broken edit menu.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages
        }
        return false
    }

    /// System Paste (Cmd+V or the edit-menu item) routed through the same
    /// clipboard handling as the toolbar Paste button: an image goes to the Mac
    /// as `terminal.paste_image`, text rides the normal input sink.
    override func paste(_ sender: Any?) {
        handlePasteAction()
    }

    // MARK: Hold-to-repeat backspace (hasText + zero-width anchor)

    /// Always report that there is text to delete.
    ///
    /// This is the legacy ``UIKeyInput`` gate (borrowed from iSH's
    /// `TerminalView`) for the software keyboard's *hold-to-repeat* backspace. On
    /// a bare ``UIKeyInput`` responder (this view) the keyboard's auto-repeat
    /// timer keeps firing ``deleteBackward()`` only while the first responder
    /// reports `hasText == true`. It is always safe to send a DEL byte to the
    /// remote terminal, so there is no "nothing to delete" state to honor —
    /// return `true` unconditionally.
    ///
    /// Internal byte-routing therefore must *not* key off `hasText` (it is a
    /// constant); ``deleteBackward()`` and the modifier guards key off
    /// ``markedText`` (IME composition) instead.
    var hasText: Bool { true }

    /// Whether the view is currently presenting the zero-width delete-repeat
    /// anchor: there is no IME composition, so the view fabricates a
    /// one-character virtual document with the caret at the end. While this is
    /// true UIKit's modern document-driven repeat path sees a deletable character
    /// to the left of the cursor and keeps firing ``deleteBackward()``. Mirrors
    /// vvterm's `usesDeleteRepeatAnchor`.
    private var usesDeleteRepeatAnchor: Bool { markedText == nil }

    /// The current zero-width anchor character. Toggling between two distinct
    /// zero-width characters on each empty-buffer delete forces the virtual
    /// document's contents to change, which is what re-arms the repeat. (vvterm:
    /// `deleteRepeatAnchorText`.)
    private var deleteRepeatAnchorText: String {
        deleteRepeatAnchorUsesAlternate ? "\u{2060}" : "\u{200B}"
    }

    /// The virtual document UIKit walks: the IME composition while marking,
    /// otherwise the one-character zero-width delete-repeat anchor.
    private var textInputDocument: String {
        usesDeleteRepeatAnchor ? deleteRepeatAnchorText : (markedText ?? "")
    }

    private var textInputDocumentLength: Int {
        (textInputDocument as NSString).length
    }

    /// The caret sits at the end of the virtual document (after the anchor char,
    /// or at the end of the marked composition) so there is always something to
    /// its left to delete.
    private var effectiveSelectedRange: NSRange {
        NSRange(location: textInputDocumentLength, length: 0)
    }

    /// Re-arm the delete-repeat anchor after an empty-buffer delete.
    ///
    /// Toggling the anchor char inside `textWillChange`/`textDidChange` brackets
    /// tells UIKit the (still one-character) virtual document changed, so the
    /// keyboard's document-driven repeat timer re-reads it and fires the next
    /// ``deleteBackward()``. Without this the modern repeat path stalls after one
    /// delete even though ``hasText`` stays `true` — this is the refinement the
    /// prior documentless attempt lacked. Mirrors vvterm's
    /// `notifyVirtualDeleteAnchorDidChange`.
    private func notifyVirtualDeleteAnchorDidChange() {
        inputDelegate?.textWillChange(self)
        deleteRepeatAnchorUsesAlternate.toggle()
        inputDelegate?.textDidChange(self)
    }

    var terminalTheme: TerminalTheme = .monokai {
        didSet {
            guard terminalTheme != oldValue else { return }
            refreshThemeColors()
        }
    }
    private var themeBarColor: UIColor { terminalTheme.terminalBackgroundUIColor }
    private var themeChromeColor: UIColor { themeBarColor.terminalReadableForeground }
    private static let accessoryHorizontalInset: CGFloat = 16
    private static let accessoryButtonFont = UIFont.systemFont(ofSize: 14, weight: .medium)
    /// One shared SF Symbol config for every icon on the bar (paste, zoom,
    /// arrows, settings, keyboard toggle) so all glyphs render at one size.
    /// The point size sits just under the 14pt text font because an SF Symbol's
    /// bounding box reads larger than text at the same size; 13pt keeps the
    /// icons visually in line with the text keys instead of looming over them.
    private static let accessoryButtonSymbolConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    /// Dedicated, slightly smaller config for the leading composer toggle.
    /// `square.and.pencil` has a denser, taller bounding box than the
    /// magnifying-glass/clipboard glyphs, so at the shared 13pt it still loomed
    /// larger than its neighbors; 11pt brings it visually in line with them.
    private static let composerButtonSymbolConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
    /// One comfortable inset applied to every button so the bar reads tappable and
    /// uniform. Each button hugs its label/icon plus this inset. The bar's vertical
    /// breathing room lives BELOW the strip (``dockedBottomPadding``), not as a
    /// scroll-view margin that would shrink the capsule inside the strip, so the
    /// glass capsule grows to fill the full strip height. The horizontal inset is
    /// trimmed so the capsule hugs its glyph.
    private static let accessoryButtonContentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
    private static let accessoryButtonCornerRadius: CGFloat = 6
    /// Button height. Equal to ``dockedNubSize`` so the capsule fills the strip
    /// vertically: the buttons are as tall as the section, with the breathing
    /// room living BELOW the strip (``dockedBottomPadding``) instead of inside it.
    private static let accessoryButtonHeight: CGFloat = dockedNubSize
    /// Size of the directional arrow nub (the tallest control in the bar). The
    /// button-row strip is sized to exactly this so the nub fills the strip with no
    /// slack above it, and the host reserves exactly this much grid height. Flush
    /// with ``accessoryButtonHeight`` (the floor below which the buttons would clip
    /// the strip) so the bar — and the reserved grid band above the keyboard — is as
    /// short as it can be while every control stays a comfortable tap target.
    static let dockedNubSize: CGFloat = 28
    /// Breathing room below the control row, between the buttons and the keyboard
    /// top (or the home indicator when the keyboard is down), so the bar is not
    /// flush-tight at its bottom while the TOP stays snug to the terminal's last
    /// row. It is part of ``dockedButtonRowHeight`` so the grid reservation, the
    /// surface frame, and the composer host all reserve the same total band; the
    /// button row itself is pinned to the BOTTOM of that band minus this padding
    /// (see the docked bar's constraints), so the extra space lands below the
    /// controls.
    static let dockedBottomPadding: CGFloat = 8
    /// Fixed height of the docked bar's button row band, reserved by the grid and
    /// the composer host. It is the tallest control (the arrow nub,
    /// ``dockedNubSize``) plus ``dockedBottomPadding`` below it. The controls are
    /// pinned to the BOTTOM of this band (minus the padding) instead of the top:
    /// when the surface-hosted container grows taller than this band (a
    /// letterbox/resize pushes the rendered terminal's bottom up), the buttons stay
    /// glued to the keyboard top and only the slack ABOVE them grows, so the
    /// control row never rides up off the keyboard. In the composer host the frame
    /// is exactly this height (no slack), so bottom-pinning is identical to
    /// top-pinning there.
    static let dockedButtonRowHeight: CGFloat = dockedNubSize + dockedBottomPadding
    /// Minimum (not fixed) button width. Text buttons (Tab, Esc, ^C, ^D) size to
    /// their intrinsic content width and only floor here so they hug their label
    /// plus the comfortable inset; single-glyph modifiers/icons (⌃ ⌥ ⌘, the arrow
    /// keys, paste) take this as a FIXED width so they stay uniform. The glyph keys
    /// hug their icon tightly; the taller capsule supplies the tap area that a
    /// wider button used to.
    private static let accessoryButtonMinWidth: CGFloat = 32
    private var accessoryButtonNormalBackground: UIColor { themeChromeColor.withAlphaComponent(0.14) }
    private var accessoryBackgroundLeadingConstraint: NSLayoutConstraint?
    private var accessoryBackgroundTrailingConstraint: NSLayoutConstraint?
    private var accessoryDismissLeadingConstraint: NSLayoutConstraint?
    private var accessoryScrollTrailingConstraint: NSLayoutConstraint?
    /// The fill behind the input accessory bar, kept so a live theme change can
    /// recolor it from the new theme's background.
    private weak var accessoryBarBackgroundView: UIView?
    func refreshThemeColors() {
        accessoryBarBackgroundView?.backgroundColor = themeBarColor
        dismissButton?.tintColor = themeChromeColor.withAlphaComponent(0.78)
        accessoryArrowNub?.applyTheme(background: themeBarColor, foreground: themeChromeColor)
        refreshAccessoryButtonStyles()
    }

    private lazy var terminalAccessoryToolbar: UIView = {
        let container = UIView()
        container.backgroundColor = .clear
        // Placeholder height until the host positions the bar via
        // `GhosttySurfaceView.bottomDockFrames()`; sized to the button-row strip so
        // the pre-layout frame matches the reserved grid height.
        container.frame = CGRect(x: 0, y: 0, width: 0, height: Self.dockedButtonRowHeight)

        let backgroundView = UIView()
        backgroundView.backgroundColor = themeBarColor
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        self.accessoryBarBackgroundView = backgroundView

        // Pinned keyboard dismiss button on the left
        let dismissButton = UIButton(type: .system)
        dismissButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down", withConfiguration: Self.accessoryButtonSymbolConfig), for: .normal)
        dismissButton.tintColor = themeChromeColor.withAlphaComponent(0.78)
        dismissButton.addTarget(self, action: #selector(handleHideKeyboard), for: .touchUpInside)
        dismissButton.accessibilityIdentifier = "terminal.inputAccessory.hideKeyboard"
        dismissButton.accessibilityLabel = String(localized: "terminal.input_accessory.hideKeyboard", defaultValue: "Hide Keyboard")
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        self.dismissButton = dismissButton

        // Scrollable action buttons
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .horizontal
        // Tighter inter-button spacing so the keys read as a compact row.
        stack.spacing = 4
        stack.alignment = .center

        stack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStackView = stack
        populateAccessoryActions()
        scrollView.addSubview(stack)

        // Arrow nub for directional pad
        let nub = TerminalArrowNubView()
        nub.applyTheme(background: themeBarColor, foreground: themeChromeColor)
        accessoryArrowNub = nub
        nub.onArrowKey = { [weak self] action in
            self?.handleNubArrow(action)
        }
        nub.translatesAutoresizingMaskIntoConstraints = false

        // The composer toggle is pinned directly in the container (like the
        // keyboard-dismiss button and the arrow nub), OUTSIDE the horizontally
        // scrollable button row. It used to be the leading item of the scrollable
        // stack, but any scroll (e.g. reaching the HIDE/customize controls at the
        // right edge of the strip) carried it off-screen left, and that offset
        // survived a hide→reveal reflow, stranding the compose button at a large
        // negative window X (~-840 in a 402pt window) where it was unhittable.
        // Pinning it makes "the composer is always one tap away" a structural
        // invariant immune to `contentOffset`, which is what the populate comment
        // below already claimed. It is not config/remote dependent, so it is built
        // once here (not rebuilt by `populateAccessoryActions`).
        let composerButton = makeAccessoryButton(for: .composer)
        self.composerButton = composerButton

        container.addSubview(backgroundView)
        container.addSubview(dismissButton)
        container.addSubview(nub)
        container.addSubview(composerButton)
        container.addSubview(scrollView)

        let backgroundLeadingConstraint = backgroundView.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        let backgroundTrailingConstraint = backgroundView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        let dismissLeadingConstraint = dismissButton.leadingAnchor.constraint(
            equalTo: container.safeAreaLayoutGuide.leadingAnchor,
            constant: Self.accessoryHorizontalInset
        )
        // The bar scrolls horizontally, so the right edge runs flush to the
        // screen (zero trailing inset). `updateAccessoryLayoutInsets` only adds a
        // safe-area inset when the surface itself does not reach the window edge.
        let scrollTrailingConstraint = scrollView.trailingAnchor.constraint(
            equalTo: container.safeAreaLayoutGuide.trailingAnchor,
            constant: 0
        )

        // A short fixed-height strip pinned to the container's BOTTOM (minus
        // ``dockedBottomPadding``) that holds the button row. The docked container
        // can be TALLER than this strip, because the host
        // (`GhosttySurfaceView.bottomDockFrames`) anchors the bar's TOP to the
        // rendered terminal's bottom and its BOTTOM to the keyboard top, so a
        // letterbox/resize that pushes the rendered terminal up grows the container
        // upward. Bottom-pinning the controls keeps them glued to the keyboard top
        // (the container's bottom edge) with the slack absorbed ABOVE them; a
        // top-pin would let the controls ride UP off the keyboard whenever the
        // terminal was letterboxed. `dockedBottomPadding` lifts the strip off the
        // very bottom edge so the controls have breathing room.
        let buttonRow = UILayoutGuide()
        container.addLayoutGuide(buttonRow)

        NSLayoutConstraint.activate([
            backgroundLeadingConstraint,
            backgroundTrailingConstraint,
            backgroundView.topAnchor.constraint(equalTo: container.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // Bottom-pinned (minus the bottom padding) so the controls hug the
            // keyboard top no matter how tall the container grows; the strip itself
            // stays exactly the nub height.
            buttonRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.dockedBottomPadding),
            buttonRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            buttonRow.heightAnchor.constraint(equalToConstant: Self.dockedNubSize),

            // Every control shares the strip's single centerline. The strip is sized
            // to the tallest control (the ``dockedNubSize`` nub), so centering keeps
            // all three groups — keyboard button, nub, and the scrollable Ctrl/Esc/Tab
            // row — on ONE horizontal line, hugging the keyboard top (the strip is
            // bottom-pinned). (Top-pinning the directly-anchored controls instead
            // would float them above the scroll row, which is centered inside its own
            // scroll view.)
            dismissLeadingConstraint,
            dismissButton.centerYAnchor.constraint(equalTo: buttonRow.centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 32),

            nub.leadingAnchor.constraint(equalTo: dismissButton.trailingAnchor, constant: 6),
            nub.centerYAnchor.constraint(equalTo: buttonRow.centerYAnchor),
            nub.widthAnchor.constraint(equalToConstant: Self.dockedNubSize),
            nub.heightAnchor.constraint(equalToConstant: Self.dockedNubSize),

            // Pinned composer toggle: directly after the nub (same 6pt gap the
            // scroll view used to take), centered on the shared strip line. The
            // scroll view starts after it with the 4pt inter-button spacing the
            // stack uses, so the bar reads identically to before — only now the
            // composer can never scroll away.
            composerButton.leadingAnchor.constraint(equalTo: nub.trailingAnchor, constant: 6),
            composerButton.centerYAnchor.constraint(equalTo: buttonRow.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: composerButton.trailingAnchor, constant: 4),
            scrollTrailingConstraint,
            scrollView.topAnchor.constraint(equalTo: buttonRow.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),

            // No vertical margin inside the scroll view: the stack fills the strip
            // height so the glass capsules grow to the full section height. The
            // bar's breathing room lives BELOW the strip (`dockedBottomPadding`),
            // not as a margin that shrinks the buttons.
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            // Zero trailing content padding so the last button runs to the screen
            // edge when scrolled to the end (the bar scrolls horizontally).
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        accessoryBackgroundLeadingConstraint = backgroundLeadingConstraint
        accessoryBackgroundTrailingConstraint = backgroundTrailingConstraint
        accessoryDismissLeadingConstraint = dismissLeadingConstraint
        accessoryScrollTrailingConstraint = scrollTrailingConstraint
        // The cmux iOS app always drives a macOS cmux surface, so default the
        // accessory to Mac modifiers: retitle Ctrl/Alt to ⌃/⌥ and insert the ⌘
        // button. `updateModifierLabels(isMacRemote:)` can still switch this if a
        // non-Mac remote is ever introduced.
        updateModifierLabels(isMacRemote: true)
        return container
    }()

    /// The terminal accessory bar (modifier keys, arrow nub, shortcut buttons).
    ///
    /// Formerly the keyboard `inputAccessoryView`; it is now docked as a
    /// persistent bottom bar by ``GhosttySurfaceView`` so it stays visible when
    /// the keyboard is dismissed and reserves space above the bottom TUI rows.
    /// Its buttons still target this text view, so the action wiring is intact
    /// regardless of where the view is hosted.
    var toolbarView: UIView { terminalAccessoryToolbar }

    private weak var accessoryStackView: UIStackView?
    private var isMacRemote = false

    #if DEBUG
    /// Regression sentinel for the hide→reveal "compose button off-screen left" jank.
    /// The composer toggle is pinned in the container (not the scrollable stack),
    /// so its window X (``composeWinX``) must stay on-screen REGARDLESS of how far the
    /// button row is scrolled (``scrollOffsetX`` can be anything up to
    /// `scrollContentW - scrollFrameW`). Before the fix the composer rode inside the
    /// scroll view and a persisted right-scroll carried it to ~-840. Appended to
    /// ``GhosttySurfaceView.composerDockProbeValue`` so it lands in the XCUITest
    /// failure message with no log plumbing.
    var accessoryLayoutDiagnostics: String {
        let scroll = accessoryStackView?.superview as? UIScrollView
        let win = window
        let scrollOffsetX = scroll.map { Int($0.contentOffset.x) } ?? -1
        let scrollContentW = scroll.map { Int($0.contentSize.width) } ?? -1
        let scrollFrameW = scroll.map { Int($0.frame.width) } ?? -1
        let composeWinX: Int = {
            guard let compose = composerButton, let win else { return -9999 }
            return Int(compose.convert(compose.bounds, to: win).minX)
        }()
        return [
            "scrollOffsetX=\(scrollOffsetX)",
            "scrollContentW=\(scrollContentW)",
            "scrollFrameW=\(scrollFrameW)",
            "composeWinX=\(composeWinX)",
        ].joined(separator: ";")
    }
    #endif

    func updateAccessoryLayoutInsets() {
        let insets = accessoryLayoutInsetsProvider?() ?? .zero
        let leftInset = max(0, insets.left)
        let rightInset = max(0, insets.right)

        accessoryBackgroundLeadingConstraint?.constant = leftInset
        accessoryBackgroundTrailingConstraint?.constant = -rightInset
        accessoryDismissLeadingConstraint?.constant = Self.accessoryHorizontalInset + leftInset
        // Right edge runs flush to the surface edge: only honor the surface's own
        // right offset from the window (when it does not span full width), not the
        // bar's leading inset, so the rightmost button hugs the screen edge.
        accessoryScrollTrailingConstraint?.constant = -rightInset

        if accessoryStackView != nil {
            terminalAccessoryToolbar.setNeedsLayout()
            terminalAccessoryToolbar.layoutIfNeeded()
        }
    }

    /// Build (or rebuild) the SCROLLABLE button row: the user's configured order
    /// (modifiers, zoom, paste, shortcuts, and custom actions all reorderable
    /// together), followed by the fixed trailing HIDE and "customize" controls.
    /// The composer toggle is NOT here — it is pinned in the container outside
    /// the scroll view (see ``terminalAccessoryToolbar``). The ⌘ item is rendered
    /// only when driving a Mac remote. Safe to call repeatedly; it clears the
    /// stack first.
    private func populateAccessoryActions() {
        guard let stack = accessoryStackView else { return }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // The composer toggle is NOT added here: it is pinned directly in the
        // container (see ``terminalAccessoryToolbar``), OUTSIDE this scrollable
        // stack, so it can never be carried off-screen by the button row's scroll
        // position. It is built once at toolbar construction (not config/remote
        // dependent), so a repopulate must not re-add or rebuild it.
        //
        // The user-configurable region: built-in shortcuts/modifiers/zoom/paste
        // and custom actions, all in the user's saved order.
        for item in TerminalAccessoryConfiguration.shared.enabledItems {
            switch item {
            case let .builtin(action):
                // ⌘ only makes sense against a Mac remote; skip it otherwise
                // (it stays in the saved order, just unrendered, so flipping the
                // remote re-shows it in place).
                if action == .command && !isMacRemote { continue }
                if action == .files && !artifactFilesEnabled { continue }
                stack.addArrangedSubview(makeAccessoryButton(for: action))
            case let .custom(custom):
                stack.addArrangedSubview(makeCustomAccessoryButton(for: custom))
            }
        }
        // The HIDE button, pinned just before "customize": temporarily hides the
        // whole bottom chrome (toolbar + composer) until the next terminal tap.
        stack.addArrangedSubview(makeHideChromeButton())
        // The "customize" button pinned at the very end of the bar.
        stack.addArrangedSubview(makeToolbarSettingsButton())

        // A modifier the user just hid (or ⌘ on a non-Mac remote) is no longer
        // rendered, so it would otherwise stay armed/sticky with no visible
        // button to turn it off and silently modify every keystroke. Clear any
        // armed modifier whose button is not on the bar.
        reconcileArmedModifierVisibility()
    }

    /// Disarm the active modifier if its bar button is no longer rendered, so a
    /// hidden (or non-Mac-remote ⌘) modifier can never stay invisibly armed.
    private func reconcileArmedModifierVisibility() {
        guard let armed = modifierState.armedModifier,
              let action = Self.accessoryAction(for: armed) else { return }
        let renderedActions = (accessoryStackView?.arrangedSubviews ?? []).compactMap { view -> TerminalInputAccessoryAction? in
            guard let button = view as? AccessoryActionButton,
                  case let .builtin(builtinAction) = button.item else { return nil }
            return builtinAction
        }
        guard !renderedActions.contains(action) else { return }
        modifierState.disarmAll()
        refreshAccessoryButtonStyles()
    }

    /// Maps a modifier-state modifier to its accessory-bar action, so the
    /// rebuild can check whether its button is currently on the bar.
    private static func accessoryAction(for modifier: TerminalInputModifier) -> TerminalInputAccessoryAction? {
        switch modifier {
        case .control: return .control
        case .alternate: return .alternate
        case .command: return .command
        case .shift: return .shift
        }
    }

    @objc private func handleAccessoryConfigurationChanged() {
        // Only rebuild once the bar exists; otherwise the lazy build picks up
        // the new configuration on first use.
        guard accessoryStackView != nil else { return }
        populateAccessoryActions()
        applyModifierPresentation()
        terminalAccessoryToolbar.setNeedsLayout()
        terminalAccessoryToolbar.layoutIfNeeded()
    }

    func updateModifierLabels(isMacRemote: Bool) {
        guard self.isMacRemote != isMacRemote else { return }
        self.isMacRemote = isMacRemote
        // The ⌘ item is rendered only for a Mac remote and modifier titles depend
        // on `isMacRemote`, so a full repopulate (rather than an in-place relabel)
        // keeps the bar correct now that ⌘ can sit anywhere in the user's order.
        populateAccessoryActions()
        applyModifierPresentation()
    }

    /// Retitle the modifier buttons for the current remote and re-apply each
    /// button's armed/sticky style. Split out of ``updateModifierLabels(isMacRemote:)``
    /// so a configuration-driven rebuild can re-apply it without toggling the flag.
    private func applyModifierPresentation() {
        if let button = composerButton as? AccessoryActionButton {
            applyAccessoryButtonStyle(button, item: button.item, armed: false, sticky: false)
        }
        guard let stack = accessoryStackView else { return }
        // Restyle every visible button for the current remote (built-in titles
        // depend on `isMacRemote`) and its armed/sticky state. Custom actions
        // never arm.
        for case let button as AccessoryActionButton in stack.arrangedSubviews {
            let armed: Bool
            let sticky: Bool
            if case let .builtin(action) = button.item {
                armed = isAccessoryActionArmed(action)
                sticky = isAccessoryActionSticky(action)
            } else {
                armed = false
                sticky = false
            }
            applyAccessoryButtonStyle(button, item: button.item, armed: armed, sticky: sticky)
        }
        let tint = themeChromeColor.withAlphaComponent(0.72)
        for case let button as UIButton in stack.arrangedSubviews where !(button is AccessoryActionButton) {
            var configuration = button.configuration
            configuration?.baseForegroundColor = tint
            button.configuration = configuration
            button.tintColor = tint
        }
        // Disarm command state if switching away from Mac remote (clears a
        // sticky lock too, matching the legacy unconditional setter).
        if !isMacRemote && commandAccessoryArmed {
            modifierState.disarmAll()
            refreshAccessoryButtonStyles()
        }
    }

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        tintColor = .clear
        // The view owns no visible content; it is a zero-size hidden responder
        // docked by `GhosttySurfaceView`. The accessory bar is no longer the
        // keyboard's `inputAccessoryView`; `GhosttySurfaceView` docks
        // `toolbarView` persistently at the bottom so it survives keyboard
        // dismissal. Leaving `inputAccessoryView` nil means the keyboard shows
        // without its own accessory (the docked bar rides above it via
        // `keyboardLayoutGuide`).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAccessoryConfigurationChanged),
            name: TerminalAccessoryConfiguration.didChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Receive a committed character (or block) from the keyboard.
    ///
    /// This is the single sink for every soft-keyboard text insertion: typed
    /// characters, an emoji-picker tap, an IME-committed candidate, and the
    /// recognized text of a dictation session (delivered as one multi-character
    /// block). It never edits a local document — it routes straight to the remote
    /// terminal. Committing here also ends any IME composition.
    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        TerminalInputDebugLog.log("proxy.insertText text=\(TerminalInputDebugLog.textSummary(text)) composing=\(markedText != nil)")
        // A committed insert ends composition. The candidate the IME was showing
        // is exactly `text`, so clear the marked state and emit `text` once.
        if markedText != nil {
            withMarkedTextChange { markedText = nil }
        }
        emitCommittedText(text, source: "insertText")
    }

    func deleteBackward() {
        // Branches route on `markedText` (IME composition in progress), NOT
        // `hasText`: `hasText` is a forced constant `true` so the software keyboard
        // auto-repeats backspace, so it can no longer mean "the local document is
        // empty". While composing, the delete shortens the marked composition by
        // one grapheme; otherwise it is a real backspace that must reach the Mac
        // (and repeats on every auto-repeat tick).
        if commandAccessoryArmed, markedText == nil {
            if !commandAccessorySticky {
                setCommandAccessoryArmed(false)
            }
            // Cmd+Backspace on Mac = delete to start of line (Ctrl+U / 0x15)
            onEscapeSequence?(Data([0x15]))
            return
        }
        if alternateAccessoryArmed, markedText == nil {
            if !alternateAccessorySticky {
                setAlternateAccessoryArmed(false)
            }
            if let output = TerminalHardwareKeyResolver.data(
                input: UIKeyCommand.inputDelete,
                modifierFlags: [.alternate]
            ) {
                onEscapeSequence?(output)
            }
            return
        }
        if controlAccessoryArmed, markedText == nil {
            if !controlAccessorySticky {
                setControlAccessoryArmed(false)
            }
            onBackspace?()
            return
        }
        if shiftAccessoryArmed, markedText == nil {
            // Shift does not change Backspace, but a one-shot ⇧ must still be
            // consumed here so it cannot leak onto the next key (matching the
            // Control branch above).
            if !shiftAccessorySticky {
                setShiftAccessoryArmed(false)
            }
            onBackspace?()
            return
        }
        // While composing, edit the marked text instead of cancelling the whole
        // candidate. The previous `UITextView` let the input system delete one
        // composing unit at a time; nuking the entire composition on the first
        // Backspace made mid-composition correction impossible for CJK/pinyin
        // input. Drop the LAST grapheme (`Character`, not a UTF-16 unit, so a
        // multi-scalar glyph is never split mid-codepoint) and re-present the
        // shortened composition through ``setMarkedText(_:selectedRange:)``,
        // which brackets the change in `textWillChange`/`textDidChange` and
        // derives both ``markedTextRange`` and ``selectedTextRange`` from the new
        // string, keeping UIKit and the IME in sync. Removing the last remaining
        // unit yields an empty string, which ``setMarkedText`` clears to `nil`
        // (composition ends and the delete-repeat anchor re-arms). Nothing is
        // sent to the Mac in either case: the composition is uncommitted.
        if let composing = markedText {
            var shortened = composing
            shortened.removeLast()
            setMarkedText(shortened, selectedRange: NSRange(location: (shortened as NSString).length, length: 0))
            return
        }
        // Empty buffer: this is a real backspace. Send DEL to the Mac and re-arm
        // the zero-width delete-repeat anchor so UIKit's document-driven repeat
        // keeps firing while the key is held.
        notifyVirtualDeleteAnchorDidChange()
        onBackspace?()
    }

    /// Test seam standing in for an IME/dictation/commit cycle.
    ///
    /// Drives the same path the keyboard would: composing text marks it (so
    /// ``markedText`` is held and the anchor is suppressed), while a
    /// non-composing change commits it. Mirrors the real
    /// ``setMarkedText(_:selectedRange:)`` → ``insertText(_:)`` flow so tests can
    /// assert routing without a live keyboard.
    func simulateTextChangeForTesting(_ text: String, isComposing: Bool) {
        if isComposing {
            setMarkedText(text, selectedRange: NSRange(location: text.count, length: 0))
        } else {
            if markedText != nil {
                withMarkedTextChange { markedText = nil }
            }
            guard !text.isEmpty else { return }
            emitCommittedText(text, source: "textChange")
        }
    }

    func simulateHardwareKeyCommandForTesting(input: String, modifierFlags: UIKeyModifierFlags) -> Bool {
        handleHardwareKeyInput(input: input, modifierFlags: modifierFlags)
    }

    func simulateAccessoryActionForTesting(_ action: TerminalInputAccessoryAction) {
        resetStickyTapTimeForTesting(action)
        handleAccessoryAction(action)
    }

    func simulateNubArrowForTesting(_ action: TerminalInputAccessoryAction) {
        handleNubArrow(action)
    }

    private func resetStickyTapTimeForTesting(_ action: TerminalInputAccessoryAction) {
        guard action.isModifier else { return }
        modifierState.clearDoubleTapWindow()
    }

    /// Route a directional-nub arrow through the same modifier-aware path as the
    /// toolbar arrow buttons.
    private func handleNubArrow(_ action: TerminalInputAccessoryAction) {
        handleAccessoryAction(action)
    }

    @objc
    private func handleHardwareKeyCommand(_ sender: UIKeyCommand) {
        guard let input = sender.input else { return }
        _ = handleHardwareKeyInput(input: input, modifierFlags: sender.modifierFlags)
    }

    @objc
    private func handleHideKeyboard() {
        onHideKeyboard?()
    }

    /// Swap the leftmost button between dismiss-keyboard (`shown == true`,
    /// chevron-down) and show-keyboard (`shown == false`, plain keyboard)
    /// glyphs, cross-dissolved, so it reads as a single keyboard toggle.
    func setKeyboardShown(_ shown: Bool) {
        guard let dismissButton else { return }
        let symbol = shown ? "keyboard.chevron.compact.down" : "keyboard"
        let image = UIImage(systemName: symbol, withConfiguration: Self.accessoryButtonSymbolConfig)
        UIView.transition(with: dismissButton, duration: 0.2, options: .transitionCrossDissolve) {
            dismissButton.setImage(image, for: .normal)
        }
        dismissButton.accessibilityLabel = shown
            ? String(localized: "terminal.input_accessory.hideKeyboard", defaultValue: "Hide Keyboard")
            : String(localized: "terminal.input_accessory.showKeyboard", defaultValue: "Show Keyboard")
    }

    @objc
    private func handleAccessoryButton(_ sender: Any) {
        guard let button = sender as? AccessoryActionButton else { return }
        switch button.item {
        case let .builtin(action):
            handleAccessoryAction(action, sourceView: button)
        case let .custom(custom):
            handleCustomAction(custom)
        }
    }

    @objc
    private func handleOpenToolbarSettings() {
        onOpenToolbarSettings?()
    }

    @objc
    private func handleHideChrome() {
        onHideChrome?()
    }

    /// Fire a custom action's bytes. Custom actions are macros, so any armed
    /// modifier is cleared first to avoid silently modifying the macro's output.
    private func handleCustomAction(_ custom: CustomToolbarAction) {
        disarmAllModifiers()
        refreshAccessoryButtonStyles()
        guard let output = custom.output else { return }
        onEscapeSequence?(output)
    }

    @discardableResult
    private func handleHardwareKeyInput(input: String, modifierFlags: UIKeyModifierFlags) -> Bool {
        guard let data = TerminalHardwareKeyResolver.data(input: input, modifierFlags: modifierFlags) else {
            return false
        }
        onEscapeSequence?(data)
        return true
    }

    private func makeAccessoryButton(for action: TerminalInputAccessoryAction) -> AccessoryActionButton {
        let button = AccessoryActionButton(item: .builtin(action))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(handleAccessoryButton(_:)), for: .touchUpInside)
        button.accessibilityIdentifier = action.accessibilityIdentifier
        button.accessibilityLabel = action.accessibilityLabel
        applyAccessoryButtonStyle(button, item: .builtin(action), armed: false, sticky: false)
        button.heightAnchor.constraint(equalToConstant: Self.accessoryButtonHeight).isActive = true
        if action.isModifier || action.symbolName != nil {
            // Single-glyph modifiers (⌃⌥⌘⇧) and icon buttons (zoom) get a fixed
            // width so they stay uniform — their glyph metrics differ, and a
            // greater-than-or-equal min-width let some (e.g. the glass capsule)
            // grow wider than others. Variable-text buttons keep growing.
            button.widthAnchor.constraint(equalToConstant: Self.accessoryButtonMinWidth).isActive = true
        } else {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.accessoryButtonMinWidth).isActive = true
        }
        return button
    }

    private func makeCustomAccessoryButton(for custom: CustomToolbarAction) -> AccessoryActionButton {
        let button = AccessoryActionButton(item: .custom(custom))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(handleAccessoryButton(_:)), for: .touchUpInside)
        button.accessibilityIdentifier = "terminal.inputAccessory.custom.\(custom.id.uuidString)"
        button.accessibilityLabel = custom.title
        // Custom actions never arm; they always render in the resting style.
        applyAccessoryButtonStyle(button, item: .custom(custom), armed: false, sticky: false)
        button.heightAnchor.constraint(equalToConstant: Self.accessoryButtonHeight).isActive = true
        if let symbolName = custom.symbolName,
           !symbolName.isEmpty,
           UIImage(systemName: symbolName) != nil {
            // Icon-only custom actions match the fixed-width modifier/zoom keys.
            button.widthAnchor.constraint(equalToConstant: Self.accessoryButtonMinWidth).isActive = true
        } else {
            // Text custom actions (e.g. "Claude") grow with their title.
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.accessoryButtonMinWidth).isActive = true
        }
        return button
    }

    /// The HIDE button. A plain `UIButton` (not an ``AccessoryActionButton``) so the
    /// armed-modifier styling/relabel loops skip it. Styled as a de-emphasized control
    /// like "customize"; tapping it temporarily hides the whole bottom chrome (toolbar
    /// + composer) until the next terminal tap. Min-width matches the glyph keys so it
    /// stays uniform.
    private func makeHideChromeButton() -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(handleHideChrome), for: .touchUpInside)
        button.accessibilityIdentifier = "terminal.inputAccessory.hideChrome"
        button.accessibilityLabel = String(
            localized: "terminal.input_accessory.hideChrome",
            defaultValue: "Hide Toolbar"
        )
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "chevron.down.square")
        config.preferredSymbolConfigurationForImage = Self.accessoryButtonSymbolConfig
        config.baseForegroundColor = themeChromeColor.withAlphaComponent(0.72)
        config.contentInsets = Self.accessoryButtonContentInsets
        button.configuration = config
        button.tintColor = themeChromeColor.withAlphaComponent(0.72)
        button.heightAnchor.constraint(equalToConstant: Self.accessoryButtonHeight).isActive = true
        button.widthAnchor.constraint(equalToConstant: Self.accessoryButtonMinWidth).isActive = true
        return button
    }

    /// The trailing button that opens the toolbar shortcuts editor. A plain
    /// `UIButton` (not an ``AccessoryActionButton``) so the armed-modifier
    /// styling/relabel loops skip it, and styled to read as a de-emphasized
    /// control rather than an insertable key.
    private func makeToolbarSettingsButton() -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(handleOpenToolbarSettings), for: .touchUpInside)
        button.accessibilityIdentifier = "terminal.inputAccessory.customize"
        button.accessibilityLabel = String(
            localized: "terminal.input_accessory.customize",
            defaultValue: "Customize Toolbar"
        )
        // Read as a control, not a glass key: no glass/fill background, a muted
        // gray tint, and a flat content layout matching the other buttons.
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "slider.horizontal.3")
        config.preferredSymbolConfigurationForImage = Self.accessoryButtonSymbolConfig
        config.baseForegroundColor = themeChromeColor.withAlphaComponent(0.72)
        config.contentInsets = Self.accessoryButtonContentInsets
        button.configuration = config
        button.tintColor = themeChromeColor.withAlphaComponent(0.72)
        button.heightAnchor.constraint(equalToConstant: Self.accessoryButtonHeight).isActive = true
        button.widthAnchor.constraint(equalToConstant: Self.accessoryButtonMinWidth).isActive = true
        return button
    }

    /// Build (or rebuild) a button's configuration for `item` and its current
    /// armed/sticky state. On iOS 26 the bar uses real Liquid Glass
    /// (`.glass()` resting, `.prominentGlass()` armed/sticky); earlier OSes keep
    /// the flat gray/blue fill the bar shipped with. Built-in modifier titles
    /// follow `isMacRemote`; custom actions render their saved title/icon and
    /// never arm.
    private func applyAccessoryButtonStyle(
        _ button: UIButton,
        item: ResolvedToolbarItem,
        armed: Bool,
        sticky: Bool
    ) {
        var config = accessoryButtonConfiguration(armed: armed, sticky: sticky)
        let symbolName: String?
        let title: String
        switch item {
        case let .builtin(action):
            symbolName = action.symbolName
            title = action.title(isMacRemote: isMacRemote)
        case let .custom(custom):
            // Only honor a custom symbol when it resolves to a real SF Symbol.
            if let name = custom.symbolName, !name.isEmpty, UIImage(systemName: name) != nil {
                symbolName = name
            } else {
                symbolName = nil
            }
            title = custom.title
        }
        if let symbolName {
            config.image = UIImage(systemName: symbolName)
            // The composer's `square.and.pencil` glyph reads heavier than the
            // other icons, so it takes a slightly smaller config to sit in line.
            let isComposer: Bool
            if case .builtin(.composer) = item { isComposer = true } else { isComposer = false }
            config.preferredSymbolConfigurationForImage = isComposer
                ? Self.composerButtonSymbolConfig
                : Self.accessoryButtonSymbolConfig
            config.attributedTitle = nil
        } else {
            var attributed = AttributedString(title)
            attributed.font = Self.accessoryButtonFont
            config.attributedTitle = attributed
            config.image = nil
        }
        config.contentInsets = Self.accessoryButtonContentInsets
        button.configuration = config
        if let actionButton = button as? AccessoryActionButton {
            actionButton.stickyLockBorderColor = UIColor.systemBlue.terminalReadableForeground
            // On iOS 26 the armed and sticky states share the same prominent-glass blue fill, so the double-tap *lock* is
            // distinguished by a white capsule border drawn over the glass (see
            // ``AccessoryActionButton/isStickyLocked``). On earlier OSes the
            // flat style already renders the locked white stroke through the
            // background configuration, so the layer border stays off to avoid
            // a doubled stroke.
            if #available(iOS 26.0, *) {
                actionButton.isStickyLocked = sticky
            } else {
                actionButton.isStickyLocked = false
            }
        }
    }

    private func accessoryButtonConfiguration(armed: Bool, sticky: Bool) -> UIButton.Configuration {
        let activeBackground = UIColor.systemBlue
        let activeForeground = activeBackground.terminalReadableForeground
        if #available(iOS 26.0, *) {
            var config: UIButton.Configuration = (armed || sticky) ? .prominentGlass() : .glass()
            config.baseForegroundColor = armed || sticky ? activeForeground : themeChromeColor
            if armed || sticky {
                config.baseBackgroundColor = activeBackground
            }
            return config
        }
        var config = UIButton.Configuration.plain()
        var background = UIBackgroundConfiguration.clear()
        if sticky {
            background.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
            background.strokeColor = activeForeground
            background.strokeWidth = 2
        } else if armed {
            background.backgroundColor = activeBackground
        } else {
            background.backgroundColor = accessoryButtonNormalBackground
        }
        background.cornerRadius = Self.accessoryButtonCornerRadius
        config.background = background
        config.baseForegroundColor = armed || sticky ? activeForeground : themeChromeColor
        return config
    }

    private func handleAccessoryAction(
        _ action: TerminalInputAccessoryAction,
        sourceView: UIView? = nil
    ) {
        if action == .composer {
            // Opening the composer moves first responder off this proxy, so clear
            // any armed modifier first (like Paste/Zoom do); otherwise a
            // Ctrl/Alt/Cmd/Shift armed before opening would linger invisibly and
            // modify the next key after the composer is dismissed.
            disarmAllModifiers()
            refreshAccessoryButtonStyles()
            onToggleComposer?()
            return
        }

        if action == .paste {
            // Paste is a clipboard read, not a key sequence: ignore any armed
            // modifier and route clipboard content to the host directly.
            disarmAllModifiers()
            refreshAccessoryButtonStyles()
            handlePasteAction()
            return
        }

        if action == .files {
            disarmAllModifiers()
            refreshAccessoryButtonStyles()
            onOpenArtifactFiles?(sourceView ?? self)
            return
        }

        if let zoomDirection = action.zoomDirection {
            disarmAllModifiers()
            refreshAccessoryButtonStyles()
            onZoom?(zoomDirection)
            return
        }

        if controlAccessoryArmed,
           !action.isModifier {
            if !controlAccessorySticky {
                setControlAccessoryArmed(false)
            }
            if let output = action.output {
                onEscapeSequence?(output)
            }
            return
        }

        if alternateAccessoryArmed,
           !action.isModifier {
            if !alternateAccessorySticky {
                setAlternateAccessoryArmed(false)
            }
            if let output = alternateAccessoryOutput(for: action) {
                onEscapeSequence?(output)
            }
            return
        }

        if commandAccessoryArmed,
           !action.isModifier {
            if !commandAccessorySticky {
                setCommandAccessoryArmed(false)
            }
            if let output = commandAccessoryOutput(for: action) {
                onEscapeSequence?(output)
            }
            return
        }

        if shiftAccessoryArmed,
           !action.isModifier {
            if !shiftAccessorySticky {
                setShiftAccessoryArmed(false)
            }
            if let output = shiftAccessoryOutput(for: action) {
                onEscapeSequence?(output)
            }
            return
        }

        switch action {
        case .control:
            toggleControlModifier()
        case .alternate:
            toggleAlternateModifier()
        case .command:
            toggleCommandModifier()
        case .shift:
            toggleShiftModifier()
        default:
            if let output = action.output {
                onEscapeSequence?(output)
            }
        }
    }

    /// Read the system clipboard for the Paste button. An image is forwarded via
    /// ``onPasteImage`` (the host uploads it to the Mac as `terminal.paste_image`
    /// and the Mac injects the resulting file path); plain text rides the normal
    /// ``onText`` input path. Images win when both are present. A large image
    /// falls back to JPEG so it stays under the Mac's 10 MB cap. Accessing the
    /// pasteboard contents here is what shows iOS's one-shot paste banner, which
    /// is the expected confirmation for an explicit Paste tap.
    private func handlePasteAction() {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages, let image = pasteboard.image {
            let maxImageBytes = 8 * 1024 * 1024
            if let png = image.pngData(), png.count <= maxImageBytes {
                onPasteImage?(png, "png")
                return
            }
            if let jpeg = image.jpegData(compressionQuality: 0.8) {
                onPasteImage?(jpeg, "jpg")
                return
            }
            if let png = image.pngData() {
                onPasteImage?(png, "png")
                return
            }
        }
        if pasteboard.hasStrings, let string = pasteboard.string, !string.isEmpty {
            onText?(string)
        }
    }

    private func disarmAllModifiers() {
        modifierState.disarmAll()
    }

    private func toggleControlModifier() {
        modifierState.tap(.control, now: Self.tapNow())
        refreshAccessoryButtonStyles()
    }

    private func toggleAlternateModifier() {
        modifierState.tap(.alternate, now: Self.tapNow())
        refreshAccessoryButtonStyles()
    }

    private func toggleCommandModifier() {
        modifierState.tap(.command, now: Self.tapNow())
        refreshAccessoryButtonStyles()
    }

    private func toggleShiftModifier() {
        modifierState.tap(.shift, now: Self.tapNow())
        refreshAccessoryButtonStyles()
    }

    private func refreshAccessoryButtonStyles() {
        applyModifierPresentation()
    }

    private func emitCommittedText(_ committedText: String, source: String) {
        TerminalInputDebugLog.log("proxy.emit source=\(source) text=\(TerminalInputDebugLog.textSummary(committedText))")
        if controlAccessoryArmed {
            if !controlAccessorySticky {
                setControlAccessoryArmed(false)
            }
            if let controlSequence = controlSequence(for: committedText) {
                onEscapeSequence?(controlSequence)
            } else {
                onText?(committedText)
            }
        } else if alternateAccessoryArmed {
            if !alternateAccessorySticky {
                setAlternateAccessoryArmed(false)
            }
            if let alternateSequence = alternateSequence(for: committedText) {
                onEscapeSequence?(alternateSequence)
            } else {
                onText?(committedText)
            }
        } else if commandAccessoryArmed {
            if !commandAccessorySticky {
                setCommandAccessoryArmed(false)
            }
            if let commandSequence = commandTextSequence(for: committedText) {
                onEscapeSequence?(commandSequence)
            } else {
                onText?(committedText)
            }
        } else if shiftAccessoryArmed {
            if !shiftAccessorySticky {
                setShiftAccessoryArmed(false)
            }
            onText?(committedText.uppercased())
        } else {
            onText?(committedText)
        }
    }

    private func alternateAccessoryOutput(for action: TerminalInputAccessoryAction) -> Data? {
        switch action {
        case .leftArrow:
            return TerminalHardwareKeyResolver.data(
                input: UIKeyCommand.inputLeftArrow,
                modifierFlags: [.alternate]
            )
        case .rightArrow:
            return TerminalHardwareKeyResolver.data(
                input: UIKeyCommand.inputRightArrow,
                modifierFlags: [.alternate]
            )
        case .control, .alternate, .command:
            return nil
        default:
            guard let output = action.output else { return nil }
            var sequence = Data([0x1B])
            sequence.append(output)
            return sequence
        }
    }

    /// Translate Cmd+<key> into the equivalent Mac-terminal readline sequence.
    /// Cmd+Left/Right = start/end of line (Ctrl+A / Ctrl+E).
    /// Cmd+Backspace is handled directly in deleteBackward() as Ctrl+U.
    private func commandAccessoryOutput(for action: TerminalInputAccessoryAction) -> Data? {
        switch action {
        case .leftArrow:
            return Data([0x01]) // Ctrl+A - beginning of line
        case .rightArrow:
            return Data([0x05]) // Ctrl+E - end of line
        case .upArrow:
            // Cmd+Up on Mac often scrolls; just send the raw arrow
            return TerminalHardwareKeyResolver.data(
                input: UIKeyCommand.inputUpArrow,
                modifierFlags: []
            )
        case .downArrow:
            return TerminalHardwareKeyResolver.data(
                input: UIKeyCommand.inputDownArrow,
                modifierFlags: []
            )
        case .control, .alternate, .command, .shift:
            return nil
        default:
            return action.output
        }
    }

    /// Translate a Shift-armed accessory key into its VT sequence. Shift+Tab is
    /// the meaningful combination — back-tab (CSI Z), which agents and TUIs use to
    /// cycle backward through fields/modes. Other keys have no distinct shifted
    /// encoding, so the unmodified key is sent (Shift is still consumed), matching
    /// how the Control branch handles special keys. Only non-modifier actions reach
    /// here (the call site guards on `!action.isModifier`), so the modifier cases
    /// are intentionally left to `default` (their `output` is `nil` regardless).
    private func shiftAccessoryOutput(for action: TerminalInputAccessoryAction) -> Data? {
        switch action {
        case .tab:
            return TerminalHardwareKeyResolver.data(input: "\t", modifierFlags: [.shift])
        default:
            return action.output
        }
    }

    private func isAccessoryActionArmed(_ action: TerminalInputAccessoryAction) -> Bool {
        switch action {
        case .control: return controlAccessoryArmed
        case .alternate: return alternateAccessoryArmed
        case .command: return commandAccessoryArmed
        case .shift: return shiftAccessoryArmed
        default: return false
        }
    }

    private func isAccessoryActionSticky(_ action: TerminalInputAccessoryAction) -> Bool {
        switch action {
        case .control: return controlAccessorySticky
        case .alternate: return alternateAccessorySticky
        case .command: return commandAccessorySticky
        case .shift: return shiftAccessorySticky
        default: return false
        }
    }

    /// Consumes a one-shot modifier after it applied to a key. Only `false`
    /// (disarm) is ever requested; a sticky lock is preserved by the reducer.
    private func consumeModifier(_ modifier: TerminalInputModifier) {
        modifierState.consumeIfNotSticky(modifier)
        refreshAccessoryButtonStyles()
    }

    private func setCommandAccessoryArmed(_ armed: Bool) {
        if !armed { consumeModifier(.command) }
    }

    private func setControlAccessoryArmed(_ armed: Bool) {
        if !armed { consumeModifier(.control) }
    }

    private func setAlternateAccessoryArmed(_ armed: Bool) {
        if !armed { consumeModifier(.alternate) }
    }

    private func setShiftAccessoryArmed(_ armed: Bool) {
        if !armed { consumeModifier(.shift) }
    }

    #if DEBUG
    /// Maps a `UIResponder` to its compact ``InputResponderIdentity`` for the
    /// composer-dock diagnostics. Used to encode *which* view owns first
    /// responder into the integer ``DiagnosticEvent`` payload. The `.other` case
    /// is paired with the responder's class name in the companion `anchormux`
    /// string log for a human-readable readback.
    static func responderIdentity(of responder: UIResponder?) -> InputResponderIdentity {
        switch responder {
        case nil: return .none
        case is TerminalInputTextView: return .terminalInputProxy
        case is GhosttySurfaceView: return .ghosttySurface
        case is UITextField: return .uiTextField
        case is UITextView: return .uiTextView
        default: return .other
        }
    }

    /// The responder's concrete class name for the human-readable `anchormux`
    /// readback (the integer ``InputResponderIdentity`` collapses every
    /// unexpected class to `.other`; this preserves the exact type for the copied
    /// debug log).
    static func responderClassName(_ responder: UIResponder?) -> String {
        guard let responder else { return "nil" }
        return String(describing: type(of: responder))
    }
    #endif
}

// MARK: - UITextInputTraits

extension TerminalInputTextView {
    // Autocorrect/predictive/smart substitutions are all off: the view forwards
    // each keystroke to the remote terminal and keeps no in-progress word for the
    // keyboard to correct against. Returning these as computed properties (rather
    // than the `UITextView` stored traits the old design used) keeps the keyboard
    // from offering corrections it could never apply.
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .default } set {} }
    var returnKeyType: UIReturnKeyType { get { .default } set {} }
}

// MARK: - UITextInput (documentless conformance + delete-repeat anchor)

// This view owns no editable document. It implements `UITextInput` to unlock two
// keyboard features a bare `UIKeyInput` view does not get — system dictation (the
// mic key) and IME marked-text composition — and to present vvterm's toggling
// one-character zero-width *delete-repeat anchor* so the software keyboard's
// modern document-driven backspace auto-repeat keeps firing while the key is
// held. Recognized dictation text and committed IME candidates both arrive
// through ``insertText(_:)`` and route to the terminal. UIKit walks the virtual
// document (`textInputDocument`) through the offset-bearing
// ``TerminalInputTextPosition`` / ``TerminalInputTextRange`` types, so positions
// and ranges carry real UTF-16 offsets rather than acting as pure identity
// sentinels — that is what lets the view report a one-character document with the
// caret at the end, the condition the repeat path checks.
extension TerminalInputTextView {
    var markedTextRange: UITextRange? {
        guard let markedText, !markedText.isEmpty else { return nil }
        return TerminalInputTextRange(start: 0, end: (markedText as NSString).length)
    }

    var selectedTextRange: UITextRange? {
        get {
            let range = effectiveSelectedRange
            return TerminalInputTextRange(start: range.location, end: range.location + range.length)
        }
        set {}
    }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set {}
    }

    var beginningOfDocument: UITextPosition { TerminalInputTextPosition(offset: 0) }
    var endOfDocument: UITextPosition { TerminalInputTextPosition(offset: textInputDocumentLength) }

    /// The IME hands a candidate string in; hold it as the marked composition so
    /// ``markedTextRange`` reports active composition (which also suppresses the
    /// delete-repeat anchor). Nothing is sent to the terminal until the candidate
    /// commits via ``insertText(_:)`` or ``unmarkText()``.
    ///
    /// Mutating ``markedText`` changes the string the view exposes through
    /// ``text(in:)``/``markedTextRange``, so it is a *text* change in the
    /// ``UITextInputDelegate`` contract: it is bracketed with
    /// `textWillChange`/`textDidChange` (via ``withMarkedTextChange(_:)``) so the
    /// IME and dictation machinery keep their composition state synchronized.
    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        TerminalInputDebugLog.log("proxy.setMarkedText text=\(TerminalInputDebugLog.textSummary(markedText ?? ""))")
        withMarkedTextChange {
            self.markedText = (markedText?.isEmpty == true) ? nil : markedText
        }
    }

    /// Brackets a mutation of ``markedText`` (or the anchor crossover when
    /// composition ends) with the `UITextInputDelegate` text-change callbacks.
    ///
    /// The marked composition is the only committed text this view exposes, so
    /// any change to it — set by the IME, committed by
    /// ``insertText(_:)``/``unmarkText()``, or canceled by ``deleteBackward()`` —
    /// is a text change UIKit must be told about with
    /// `textWillChange`/`textDidChange`. Selection-only callbacks would leave the
    /// keyboard observing stale composition state.
    private func withMarkedTextChange(_ mutate: () -> Void) {
        inputDelegate?.textWillChange(self)
        mutate()
        inputDelegate?.textDidChange(self)
    }

    /// Commit the in-progress IME composition. Forwards the held candidate to the
    /// terminal as one block.
    func unmarkText() {
        guard let composing = markedText else { return }
        withMarkedTextChange { markedText = nil }
        emitCommittedText(composing, source: "unmarkText")
    }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? TerminalInputTextRange else { return nil }
        let document = textInputDocument as NSString
        let clamped = clampedDocumentRange(range.nsRange, length: document.length)
        guard clamped.length > 0 else { return "" }
        return document.substring(with: clamped)
    }

    /// Commit text delivered through a range replacement.
    ///
    /// Most committed input arrives via ``insertText(_:)``, but some system paths
    /// (text replacement, certain dictation/suggestion commits) deliver it by
    /// replacing ``selectedTextRange`` or ``markedTextRange`` instead. The view
    /// holds no addressable document, so the range itself is ignored, but the
    /// *text* must still reach the terminal — route it through the same commit
    /// path as ``insertText(_:)``. A replacement of the marked region supersedes
    /// the in-progress IME composition, so clear it first. An empty replacement is
    /// a pure deletion of the marked composition (no committed text to send).
    func replace(_ range: UITextRange, withText text: String) {
        TerminalInputDebugLog.log("proxy.replace text=\(TerminalInputDebugLog.textSummary(text))")
        if markedText != nil {
            withMarkedTextChange { markedText = nil }
        }
        guard !text.isEmpty else { return }
        emitCommittedText(text, source: "replace")
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TerminalInputTextPosition,
              let to = toPosition as? TerminalInputTextPosition else { return nil }
        return TerminalInputTextRange(start: from.offset, end: to.offset)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? TerminalInputTextPosition else { return nil }
        let target = min(max(position.offset + offset, 0), textInputDocumentLength)
        return TerminalInputTextPosition(offset: target)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        guard let position = position as? TerminalInputTextPosition else { return nil }
        let delta = (direction == .right || direction == .down) ? offset : -offset
        let target = min(max(position.offset + delta, 0), textInputDocumentLength)
        return TerminalInputTextPosition(offset: target)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let lhs = position as? TerminalInputTextPosition,
              let rhs = other as? TerminalInputTextPosition else { return .orderedSame }
        if lhs.offset < rhs.offset { return .orderedAscending }
        if lhs.offset > rhs.offset { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let from = from as? TerminalInputTextPosition,
              let to = toPosition as? TerminalInputTextPosition else { return 0 }
        return to.offset - from.offset
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? { nil }
    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? { nil }
    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}
    func firstRect(for range: UITextRange) -> CGRect { .zero }
    func caretRect(for position: UITextPosition) -> CGRect { .zero }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { nil }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { nil }
    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    private func clampedDocumentRange(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let rangeLength = min(max(range.length, 0), max(length - location, 0))
        return NSRange(location: location, length: rangeLength)
    }

    // MARK: Dictation placeholder hooks
    //
    // UIKit calls these when the mic is tapped. Returning a placeholder (an empty
    // token; iSH does the same) is what tells the framework this view accepts
    // dictation; the recognized text then arrives via `insertText`. The remove
    // hook is a no-op because there is no document placeholder to strip.
    func insertDictationResultPlaceholder() -> Any { "" }
    func removeDictationResultPlaceholder(_ placeholder: Any, willInsertResult: Bool) {}
}
