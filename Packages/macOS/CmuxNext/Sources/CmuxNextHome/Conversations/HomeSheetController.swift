public import AppKit
public import CmuxHomeCore
import CmuxNextDesign

/// The frame of the Home page's sheets (Invite, Invite to Team, New Chief): a
/// title, the sheet's own content, a status line that says why an action
/// did not finish, and Cancel plus a default button. `run` disables the
/// buttons while the action runs; an opened conversation or a sent invite
/// closes the sheet and reaches `onFinish`. ``HomeSheetPresenter`` shows it as
/// the window's dialog overlay.
public class HomeSheetController: NSViewController {
    /// The sheet finished with a conversation to show (nil: nothing to show).
    public var onFinish: (ConversationID?) -> Void = { _ in }

    let titleLabel = ThemedLabel(labelWithString: "")
    let stack = NSStackView()
    let statusLabel = ThemedLabel(wrappingLabelWithString: "")
    let cancelButton = ThemedBezelButton(title: HomeConversationStrings.cancel, target: nil, action: nil)
    let primaryButton = ThemedDefaultButton(title: "", target: nil, action: nil)
    let buttons = NSStackView()
    /// The sheet's material, under its content: this Mac's glass with no card fill, like every
    /// overlay, solid only under Reduce Transparency (Leo 2026-10-21: "glass is never opaque (the
    /// only exception is the Reduce Transparency fallback)"). A dialog overlay has no window to
    /// shape it: the glass carries the panel's corners.
    let surface = OverlaySurfaceView(interactive: true)
    /// Ends the presentation (``HomeSheetPresenter`` sets it): the overlay's dismiss.
    var dismissPresentation: (() -> Void)?
    /// `onFinish` ran: a Cancel and the overlay's own Escape end the sheet once.
    private var finished = false
    private(set) var isRunning = false
    // task-owner: the sheet's one running action; cancelled when the sheet closes
    private var work: Task<Void, Never>?

    init(title: String, primary: String) {
        super.init(nibName: nil, bundle: nil)
        titleLabel.stringValue = title
        primaryButton.title = primary
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func loadView() {
        // The sheet's glass fills it, under the stack; the surface re-reads the theme itself.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        surface.frame = root.bounds
        surface.autoresizingMask = [.width, .height]
        // The sheet is a window of its own: the vibrancy fallback blurs the window behind it.
        surface.samplesBehindWindow = true
        root.addSubview(surface)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space3
        stack.edgeInsets = NSEdgeInsets(top: Metrics.space6, left: Metrics.space6, bottom: Metrics.space6, right: Metrics.space6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Typography.title
        titleLabel.setAccessibilityRole(.staticText)
        stack.addArrangedSubview(titleLabel)
        addContent(to: stack)
        statusLabel.isHidden = true
        statusLabel.font = Typography.caption
        statusLabel.ink = .secondary
        statusLabel.setAccessibilityIdentifier("cmux.home.sheet.status")
        stack.addArrangedSubview(statusLabel)
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyHint = .escape
        primaryButton.target = self
        primaryButton.action = #selector(primary(_:))
        primaryButton.keyHint = .return
        primaryButton.setAccessibilityIdentifier("cmux.home.sheet.primary")
        buttons.orientation = .horizontal
        buttons.spacing = Metrics.space3
        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(cancelButton)
        buttons.addArrangedSubview(primaryButton)
        stack.addArrangedSubview(buttons)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 420),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Metrics.space6),
        ])
        view = root
        refreshPrimary()
    }

    /// The control that takes the keyboard when the sheet shows (subclasses name their first field).
    var initialResponder: NSView? { nil }

    /// Subclasses add their fields between the title and the status line.
    func addContent(to stack: NSStackView) {}

    /// Whether the default button may run now (subclasses check their fields).
    var canSubmit: Bool { true }

    /// The default button's action; subclasses call `run`.
    func submit() {}

    func refreshPrimary() {
        primaryButton.isEnabled = canSubmit && !isRunning
    }

    /// Runs `action`: an opened conversation or a sent invite closes the
    /// sheet; anything else stays and says why.
    final func run(_ action: @escaping @MainActor () async -> HomeComposeOutcome) {
        guard !isRunning else { return }
        isRunning = true
        show(nil)
        refreshPrimary()
        work = Task { [weak self] in
            let outcome = await action()
            guard let self, !Task.isCancelled else { return }
            isRunning = false
            refreshPrimary()
            finish(outcome)
        }
    }

    /// Handles a finished action's outcome (subclasses add offers, such as
    /// Invite by Email after `notReachable`).
    func finish(_ outcome: HomeComposeOutcome) {
        switch outcome {
        case .opened(let id): close(showing: id)
        case .invited(let id): close(showing: id)
        default: show(HomeConversationStrings.outcome(outcome))
        }
    }

    /// The status line; nil hides it. VoiceOver hears it.
    func show(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text == nil
        if let text {
            NSAccessibility.post(element: statusLabel, notification: .announcementRequested, userInfo: [.announcement: text])
        }
    }

    func close(showing id: ConversationID?) {
        work?.cancel()
        if let dismissPresentation {
            self.dismissPresentation = nil
            dismissPresentation()
        } else if let presenting = presentingViewController {
            presenting.dismiss(self)
        } else if let window = view.window, let parent = window.sheetParent {
            parent.endSheet(window)
        }
        end(showing: id)
    }

    /// The overlay ended on its own (Escape, its window closed): the action stops and
    /// `onFinish` hears nothing to show.
    func presentationEnded() {
        dismissPresentation = nil
        work?.cancel()
        end(showing: nil)
    }

    private func end(showing id: ConversationID?) {
        guard !finished else { return }
        finished = true
        onFinish(id)
    }

    @objc func cancel(_ sender: Any?) { close(showing: nil) }
    @objc func primary(_ sender: Any?) { if canSubmit, !isRunning { submit() } }

    /// A themed text field with a placeholder; `boxed` gives it its field box.
    static func field(placeholder: String, identifier: String) -> ThemedTextField {
        let field = ThemedTextField()
        field.font = Typography.body
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    /// `field` on the theme's field fill, as wide as the sheet.
    static func boxed(_ field: NSTextField) -> ThemedFieldBox {
        let box = ThemedFieldBox(field: field, height: Metrics.controlHeight)
        box.widthAnchor.constraint(equalToConstant: 420 - 2 * Metrics.space6).isActive = true
        return box
    }
}
