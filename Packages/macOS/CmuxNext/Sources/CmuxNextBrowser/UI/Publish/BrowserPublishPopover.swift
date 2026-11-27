import AppKit
import CmuxNextBrowserCore
import CmuxNextDesign

/// The browser pane's Publish popover (RFD 0003 E-A, behind `experiments.appsTier`, off by
/// default), under the toolbar's Publish button. Native rows on the shared popup host
/// (``NativePopupHost``) and the overlay glass, no SwiftUI. The App decides what it shows
/// (``BrowserPublishSource``, from the Apps tier's Rust rules): the name field asks for the form
/// again on every edit, and Publish runs the publish and shows its answer, the app's URL with
/// Open, or the failure's code and message. One per toolbar (``BrowserToolbarButtonsView/publishPopover``).
@MainActor
public final class BrowserPublishPopover: NSObject, NSTextFieldDelegate {
    static let width: CGFloat = 300
    private static let padding = BrowserMetrics.overlayPadding

    private weak var buttons: BrowserToolbarButtonsView?
    private let popup = NativePopupHost(panel: NativePopupPanel(identifier: "cmux.browser.publish"))
    private var source: BrowserPublishSource?
    /// What the App made of the typed name and the audience (nil: it could not).
    private(set) var form: BrowserPublishForm?
    private var running: Task<Void, Never>?
    private var published: URL?
    private weak var anchor: NSView?

    private let titleLabel = ThemedLabel(labelWithString: Strings.publishTitle)
    private let nameField = ThemedTextField(frame: .zero)
    private let hostLabel = ThemedLabel(labelWithString: "")
    private let audience = NSSegmentedControl(labels: [Strings.publishPrivate, Strings.publishTeam],
                                              trackingMode: .selectOne, target: nil, action: nil)
    private let startFrom = ThemedLabel(labelWithString: "")
    private let problem = ThemedLabel(wrappingLabelWithString: "")
    private let result = ThemedLabel(wrappingLabelWithString: "")
    private let spinner = StatusIndicatorView.spinner()
    private let openButton = ThemedBezelButton()
    private let publishButton = ThemedBezelButton()
    private let stack = NSStackView()
    private var card: NSView?

    init(buttons: BrowserToolbarButtonsView) {
        self.buttons = buttons
        super.init()
        popup.onDismiss = { [weak self] in self?.closed() }
    }

    public var isShown: Bool { popup.isShown }

    /// The Publish button: opens the popover for `source`, or closes it when it is open.
    public func toggle(_ source: BrowserPublishSource) {
        guard let buttons, let anchor = buttons.popupAnchor(for: .publish), let window = anchor.window else { return }
        if popup.isShown { return close() }
        running?.cancel()
        running = nil
        self.anchor = anchor
        self.source = source
        published = nil
        if card == nil { makeCard() }
        nameField.stringValue = source.suggestedName
        audience.selectedSegment = 0
        setRunning(false)
        result.isHidden = true
        openButton.isHidden = true
        recompute()
        popup.panel.adoptThemeScope(of: anchor)
        popup.keepsOpen = { [weak anchor] event in
            guard let anchor, event.window === anchor.window else { return false }
            return anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
        }
        guard place(in: window, makeKey: true) else { return }
        buttons.setPopupOpen(true, anchor: anchor)
        buttons.onDetach = { [weak self] in self?.close() }
        FocusRoute(.person, "the Publish popover opened: its name field").moveKeyboard(in: popup.panel, to: nameField)
    }

    public func close() {
        popup.hide()
        closed()
    }

    // MARK: - Rows

    private func makeCard() {
        let inner = Self.width - 2 * Self.padding
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        nameField.placeholderString = Strings.publishNamePlaceholder
        nameField.delegate = self
        nameField.setAccessibilityIdentifier("cmux.browser.publish.name")
        hostLabel.ink = .secondary
        hostLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hostLabel.lineBreakMode = .byTruncatingMiddle
        audience.target = self
        audience.action = #selector(audienceChanged)
        audience.setAccessibilityIdentifier("cmux.browser.publish.audience")
        let startCaption = ThemedLabel(labelWithString: Strings.publishStartFrom)
        startCaption.ink = .secondary
        startFrom.lineBreakMode = .byTruncatingMiddle
        let startRow = NSStackView(views: [startCaption, startFrom])
        startRow.spacing = Metrics.space2
        for label in [problem, result] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.preferredMaxLayoutWidth = inner
            label.isSelectable = true
            label.focusRingType = .none
        }
        problem.ink = .secondary
        openButton.title = Strings.publishOpen
        openButton.target = self
        openButton.action = #selector(openPublished)
        publishButton.title = Strings.toolbarPublish
        publishButton.keyHint = .return
        publishButton.target = self
        publishButton.action = #selector(publish)
        publishButton.setAccessibilityIdentifier("cmux.browser.publish.go")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [spinner, spacer, openButton, publishButton])
        actions.spacing = Metrics.space2
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space3
        stack.edgeInsets = NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        for view in [titleLabel, nameField, hostLabel, audience, startRow, problem, result, actions] { stack.addArrangedSubview(view) }
        for view in [nameField, actions] { view.widthAnchor.constraint(equalToConstant: inner).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        // Concentric with the Publish button `padding` in (the card corner is the button's plus the padding).
        let card = Glass.makeOverlayPanel(content: stack, cornerRadius: Metrics.buttonContainer(padding: Self.padding).outerRadius)
        popup.panel.adoptPopupStyle(card: card)
        self.card = card
    }

    private var typedName: String? {
        let typed = nameField.stringValue
        return typed == source?.suggestedName ? nil : typed
    }

    private var team: Bool { audience.selectedSegment == 1 }

    /// Asks the App again for the typed name and audience, and shows its answer.
    private func recompute() {
        guard let source else { return }
        form = source.form(typedName, team)
        hostLabel.stringValue = form?.hostLabel ?? ""
        hostLabel.isHidden = form?.hostLabel == nil
        startFrom.stringValue = form?.startFrom ?? ""
        let reason: String? = switch form?.problem {
        case nil: form == nil ? Strings.publishUnavailable : nil
        case .nameEmpty: Strings.publishNameEmpty
        case .other: Strings.publishUnavailable
        }
        problem.stringValue = reason ?? ""
        problem.isHidden = reason == nil
        publishButton.isEnabled = running == nil && form?.canPublish == true
        resize()
    }

    public func controlTextDidChange(_ notification: Notification) { recompute() }

    @objc private func audienceChanged() { recompute() }

    // MARK: - Publish

    private func setRunning(_ on: Bool) {
        spinner.spin(on)
        spinner.isHidden = !on
        nameField.isEnabled = !on
        audience.isEnabled = !on
    }

    @objc private func publish() {
        guard running == nil, form?.canPublish == true, let source else { return }
        let name = typedName, team = team
        publishButton.isEnabled = false
        setRunning(true)
        result.isHidden = true
        openButton.isHidden = true
        // task-owner: the popover's wait for its one publish; closing or reopening cancels the wait and drops its answer
        // (the run itself finishes: ``BrowserPublishSource/publish`` outlives it).
        running = Task { [weak self] in
            let answer = await source.publish(name, team)
            guard let self, !Task.isCancelled else { return }
            self.finished(answer)
        }
    }

    private func finished(_ answer: BrowserPublishAnswer) {
        running = nil
        setRunning(false)
        let url: URL?
        switch answer {
        case .published(let link):
            url = link
            result.stringValue = link.map { Strings.publishPublished($0.absoluteString) }
                ?? Strings.publishPublishedNamed(typedName ?? source?.suggestedName ?? "")
        case .failed(let code, let message): url = nil; result.stringValue = Strings.publishFailed(code: code, message: message)
        case .unreadable(let exit): url = nil; result.stringValue = Strings.publishUnreadable(exit)
        case .unreachable(let reason): url = nil; result.stringValue = Strings.publishUnreachable(reason)
        }
        result.ink = url == nil ? .danger : .primary
        result.isHidden = false
        published = url
        openButton.isHidden = url == nil
        recompute()
    }

    @objc private func openPublished() {
        guard let published, let source else { return }
        close()
        source.open(published)
    }

    // MARK: - Placement

    private func resize() {
        guard popup.isShown, let anchor, let window = anchor.window else { return }
        guard !anchor.isHiddenOrHasHiddenAncestor else { return close() }
        place(in: window, makeKey: popup.panel.isKeyWindow)
    }

    @discardableResult
    private func place(in window: NSWindow, makeKey: Bool) -> Bool {
        guard let anchor else { return false }
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let rect = window.convertToScreen(anchor.convert(CmuxPopoverAnchor.rect(in: anchor), to: nil))
        return popup.show(size: CGSize(width: ceil(size.width), height: ceil(size.height)), anchor: rect, in: window,
                          preferred: .below, trailing: true, makeKey: makeKey) != nil
    }

    private func closed() {
        running?.cancel()
        running = nil
        buttons?.onDetach = nil
        if let anchor { buttons?.setPopupOpen(false, anchor: anchor) }
        anchor = nil
    }
}
