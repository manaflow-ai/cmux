import AppKit
import CmuxNextDesign

/// The quit sheet: explains that terminals run in cmux-tui and outlive the
/// app, shows how many local terminals and running programs Quit keeps and
/// the busiest programs, and asks Keep Sessions Running (default, Return),
/// End All Sessions, or Cancel (Escape), with "Don't ask again". When only
/// incognito terminals are at stake it is the incognito close confirmation
/// (Quit, Cancel). A glass panel attached as a sheet to `window`, or a
/// floating panel when no window is open.
@MainActor
final class QuitSheet {
    enum Answer: Equatable {
        case quit(QuitSessionsChoice, remember: Bool)
        case cancel
    }

    static let accessibilityID = "app.quitSheet"
    static let contentWidth: CGFloat = 400

    let prompt: QuitPrompt
    private let panel: QuitSheetPanel
    private let body = ThemeChangeView()
    private var colored: [(NSTextField, Role)] = []
    private let remember = QuitSheetCheckbox(title: QuitStrings.dontAskAgain)
    private(set) var buttons: [(id: String, button: QuitSheetButton)] = []
    private(set) var lines: [String] = []
    private var completion: ((Answer) -> Void)?

    init(prompt: QuitPrompt, completion: @escaping (Answer) -> Void) {
        self.prompt = prompt
        self.completion = completion
        panel = QuitSheetPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless],
                               backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.onCancel = { [weak self] in self?.finish(.cancel) }
        remember.isChecked = false
        remember.toolTip = QuitStrings.dontAskAgainHelp
        panel.contentView = makeContent()
        body.onThemeChange = { [weak self] in self?.applyColors() }
    }

    private enum Role { case primary, secondary, tertiary }

    /// Label colors and the glass tint, resolved in the sheet's scope (the
    /// window's room theme) whenever it changes.
    private func applyColors() {
        body.performWithTheme {
            for (field, role) in colored {
                field.textColor = switch role {
                case .primary: Palette.textPrimary
                case .secondary: Palette.textSecondary
                case .tertiary: Palette.textTertiary
                }
            }
            (body.superview as? NSGlassEffectView)?.tintColor = Palette.glassTint
        }
    }

    var isPresented: Bool { completion != nil }
    /// Attached to a window (else a floating panel).
    var isAttachedSheet: Bool { panel.sheetParent != nil }
    var remembers: Bool {
        get { remember.isChecked }
        set { remember.isChecked = newValue }
    }

    // MARK: Content

    private func makeContent() -> NSView {
        var rows: [NSView] = []
        let title = prompt.offersSessionChoice ? QuitStrings.title : ConfirmationStrings.quitIncognitoTitle
        rows.append(label(title, size: 15, weight: .semibold, role: .primary))
        if prompt.offersSessionChoice {
            rows.append(wrapping(QuitStrings.body, role: .secondary))
            rows.append(stats())
            if !prompt.busiest.isEmpty {
                rows.append(wrapping(QuitStrings.busiest(prompt.busiest.joined(separator: ", ")), role: .secondary))
            }
            if !prompt.incognitoPrograms.isEmpty {
                rows.append(wrapping(QuitStrings.incognito(prompt.incognitoPrograms.joined(separator: ", ")), role: .secondary))
            }
        } else {
            rows.append(wrapping(ConfirmationStrings.incognitoBody(prompt.incognitoPrograms.joined(separator: ", ")),
                                 role: .secondary))
        }
        if prompt.remoteSessions { rows.append(wrapping(QuitStrings.remote, role: .tertiary)) }
        if prompt.offersSessionChoice { rows.append(remember) }
        rows.append(buttonRow())

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(6, after: rows[0])
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            stack.topAnchor.constraint(equalTo: body.topAnchor),
            stack.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth + 44),
        ])
        let glass = Glass.makePanel(content: body)
        glass.setAccessibilityIdentifier(Self.accessibilityID)
        glass.setAccessibilityRole(.sheet)
        glass.setAccessibilityLabel(title)
        return glass
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, role: Role) -> NSTextField {
        lines.append(text)
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        colored.append((field, role))
        return field
    }

    private func wrapping(_ text: String, role: Role) -> NSTextField {
        lines.append(text)
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        colored.append((field, role))
        field.preferredMaxLayoutWidth = Self.contentWidth
        field.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return field
    }

    private func stats() -> NSView {
        let terminals = stat(prompt.terminals, QuitStrings.terminals)
        let running = stat(prompt.runningPrograms, QuitStrings.runningPrograms)
        let row = NSStackView(views: [terminals, running])
        row.spacing = 28
        return row
    }

    private func stat(_ value: Int, _ caption: String) -> NSView {
        let number = label(value.formatted(), size: 22, weight: .semibold, role: .primary)
        number.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        let text = label(caption, size: NSFont.smallSystemFontSize, role: .secondary)
        let column = NSStackView(views: [number, text])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.setAccessibilityElement(true)
        column.setAccessibilityLabel("\(caption): \(value)")
        return column
    }

    private func buttonRow() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let cancel = add("cancel", ConfirmationStrings.cancel, .plain, #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        var views: [NSView] = [spacer, cancel]
        if prompt.offersSessionChoice {
            let end = add("end", QuitStrings.end, prompt.defaultChoice == .end ? .primary : .destructive, #selector(endPressed))
            let keep = add("keep", QuitStrings.keep, prompt.defaultChoice == .keep ? .primary : .plain, #selector(keepPressed))
            (prompt.defaultChoice == .end ? end : keep).keyEquivalent = "\r"
            views += [end, keep]
        } else {
            let quit = add("quit", ConfirmationStrings.quit, .primary, #selector(keepPressed))
            quit.keyEquivalent = "\r"
            views.append(quit)
        }
        let row = NSStackView(views: views)
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return row
    }

    private func add(_ id: String, _ title: String, _ style: QuitSheetButton.Style, _ action: Selector) -> QuitSheetButton {
        let button = QuitSheetButton(title: title, style: style, target: self, action: action)
        button.setAccessibilityIdentifier("\(Self.accessibilityID).\(id)")
        buttons.append((id, button))
        return button
    }

    // MARK: Presenting

    /// Shows the sheet on `window` (a visible, not minimized window), else
    /// as a floating panel. Never activates the app in a no-activate launch.
    func present(in window: NSWindow?) {
        body.layoutSubtreeIfNeeded()
        panel.setContentSize(body.fittingSize)
        if let window, window.isVisible, !window.isMiniaturized {
            window.themeScope.adopt(panel)
            window.beginSheet(panel) { [weak self] response in
                // Ended by someone else (SheetDismissal): a cancel.
                if response == .cancel { self?.finish(.cancel) }
            }
            return
        }
        ThemeScope.app.adopt(panel)
        panel.level = .floating
        panel.center()
        if WindowPlacement.noActivate {
            panel.orderFrontRegardless()
        } else {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Presses the button `id` ("keep", "end", "quit", "cancel") as a click
    /// does. False when the sheet has no such button.
    @discardableResult
    func press(_ id: String) -> Bool {
        guard let button = buttons.first(where: { $0.id == id })?.button else { return false }
        button.performClick(nil)
        return true
    }

    @objc private func keepPressed() { finish(.quit(.keep, remember: prompt.offersSessionChoice && remember.isChecked)) }
    @objc private func endPressed() { finish(.quit(.end, remember: remember.isChecked)) }
    @objc private func cancelPressed() { finish(.cancel) }

    /// Closes the sheet and reports `answer` once.
    private func finish(_ answer: Answer) {
        guard let completion else { return }
        self.completion = nil
        if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: .OK) } else { panel.orderOut(nil) }
        completion(answer)
    }
}
