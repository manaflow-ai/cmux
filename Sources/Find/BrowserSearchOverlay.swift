import AppKit
import Bonsplit
import CmuxFoundation
import Combine

@MainActor
struct NativeSearchOverlayConfiguration {
    let identity: UUID
    let debugScope: String
    let fieldAccessibilityIdentifier: String
    let selectionOwner: AnyObject
    let stateChanges: AnyPublisher<Void, Never>
    let needle: () -> String
    let setNeedle: (String) -> Void
    let selected: () -> UInt?
    let total: () -> UInt?
    let focusNotificationName: Notification.Name
    let matchesFocusNotification: (Notification) -> Bool
    let canApplyFocusRequest: () -> Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    let onTextChanged: () -> Void
    let onFieldDidFocus: () -> Void
}

/// Shared AppKit find bar used by terminal and browser surfaces.
@MainActor
class NativeSearchOverlayView: NSView, NSTextFieldDelegate {
    private enum Corner {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    private let bar = NSView()
    private let field = NativeSearchTextField(frame: .zero)
    private let countLabel = NSTextField(labelWithString: "")
    private var configuration: NativeSearchOverlayConfiguration
    private var cancellables: Set<AnyCancellable> = []
    private var searchFocusObserver: NSObjectProtocol?
    private var lastSelectedRange: NSRange?
    private var isProgrammaticMutation = false
    private var corner: Corner = .topRight
    private var dragStartFrame = NSRect.zero

    override var isFlipped: Bool { true }

    init(configuration: NativeSearchOverlayConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setupView()
        bindSearchState()
        installFocusObserver()
#if DEBUG
        cmuxDebugLog("\(configuration.debugScope).findbar.appear id=\(configuration.identity.uuidString.prefix(5))")
#endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let searchFocusObserver {
            NotificationCenter.default.removeObserver(searchFocusObserver)
        }
    }

    func update(configuration: NativeSearchOverlayConfiguration) {
        let stateChanged = self.configuration.selectionOwner !== configuration.selectionOwner
        let focusRoutingChanged = self.configuration.identity != configuration.identity
            || self.configuration.focusNotificationName != configuration.focusNotificationName
        self.configuration = configuration
        field.setAccessibilityIdentifier(configuration.fieldAccessibilityIdentifier)
        field.cmuxSelectionOwner = configuration.selectionOwner
        if stateChanged { bindSearchState() }
        if focusRoutingChanged { installFocusObserver() }
        synchronizeFromModel()
        requestFocus(selectAll: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.requestFocus(selectAll: false)
        }
    }

    override func layout() {
        super.layout()
        positionBar(animated: false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        let barPoint = convert(point, to: bar)
        guard bar.bounds.contains(barPoint) else { return nil }
        return super.hitTest(point)
    }

    private func setupView() {
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 8
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        bar.shadow = NSShadow()
        bar.shadow?.shadowBlurRadius = 4
        bar.shadow?.shadowOffset = NSSize(width: 0, height: -1)
        bar.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.25)
        addSubview(bar)

        field.font = GlobalFontMagnification.systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = String(localized: "search.placeholder", defaultValue: "Search")
        field.setAccessibilityIdentifier(configuration.fieldAccessibilityIdentifier)
        field.delegate = self
        field.cmuxSelectionOwner = configuration.selectionOwner
        field.cmuxOnEscape = { [weak self] textView in self?.handleEscape(from: textView) ?? false }

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right

        let fieldContainer = NSView()
        fieldContainer.wantsLayer = true
        fieldContainer.layer?.cornerRadius = 6
        fieldContainer.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        field.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        fieldContainer.addSubview(field)
        fieldContainer.addSubview(countLabel)
        NSLayoutConstraint.activate([
            fieldContainer.widthAnchor.constraint(equalToConstant: 238),
            fieldContainer.heightAnchor.constraint(equalToConstant: 30),
            field.leadingAnchor.constraint(equalTo: fieldContainer.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: fieldContainer.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: fieldContainer.trailingAnchor, constant: -8),
            countLabel.centerYAnchor.constraint(equalTo: fieldContainer.centerYAnchor),
            countLabel.widthAnchor.constraint(equalToConstant: 46),
        ])

        let controls = NSStackView(views: [
            fieldContainer,
            searchButton(
                symbol: "chevron.up",
                help: String(localized: "search.nextMatch.help", defaultValue: "Next match (Return)"),
                selector: #selector(next)
            ),
            searchButton(
                symbol: "chevron.down",
                help: String(localized: "search.previousMatch.help", defaultValue: "Previous match (Shift+Return)"),
                selector: #selector(previous)
            ),
            searchButton(
                symbol: "xmark",
                help: String(localized: "search.close.help", defaultValue: "Close (Esc)"),
                selector: #selector(close)
            ),
        ])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 4
        controls.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            controls.topAnchor.constraint(equalTo: bar.topAnchor, constant: 8),
            controls.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -8),
        ])

        bar.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(dragBar(_:))))
        synchronizeFromModel()
    }

    private func searchButton(symbol: String, help: String, selector: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage(),
            target: self,
            action: selector
        )
        button.title = ""
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private func bindSearchState() {
        cancellables.removeAll()
        configuration.stateChanges
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    self?.synchronizeFromModel()
                }
            }
            .store(in: &cancellables)
    }

    private func synchronizeFromModel() {
        let needle = configuration.needle()
        if let editor = field.currentEditor() as? NSTextView {
            if editor.string != needle, !editor.hasMarkedText() {
                let selection = field.cmuxRememberSelection(editor.selectedRange(), in: needle)
                isProgrammaticMutation = true
                editor.string = needle
                field.stringValue = needle
                editor.setSelectedRange(selection)
                lastSelectedRange = selection
                cmuxStoreFindSelection(selection, for: configuration.selectionOwner)
                isProgrammaticMutation = false
            }
        } else if field.stringValue != needle {
            field.stringValue = needle
        }
        if let selected = configuration.selected() {
            countLabel.stringValue = "\(selected + 1)/\(configuration.total().map(String.init) ?? "?")"
        } else if let total = configuration.total() {
            countLabel.stringValue = total == 0 ? "0/0" : "-/\(total)"
        } else {
            countLabel.stringValue = ""
        }
    }

    private func installFocusObserver() {
        if let searchFocusObserver {
            NotificationCenter.default.removeObserver(searchFocusObserver)
        }
        searchFocusObserver = NotificationCenter.default.addObserver(
            forName: configuration.focusNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.configuration.matchesFocusNotification(notification) else { return }
                let selectAll = notification.userInfo?[FindFocusNotificationKey.selectAll] as? Bool == true
                self.requestFocus(selectAll: selectAll)
            }
        }
    }

    private func requestFocus(selectAll: Bool) {
        guard configuration.canApplyFocusRequest(), let window else { return }
        let alreadyFocused = cmuxTextFieldIsFirstResponder(field, in: window)
        guard alreadyFocused || window.makeFirstResponder(field) else { return }
        let remembered = field.cmuxLastSelectedRange
            ?? cmuxStoredFindSelection(for: configuration.selectionOwner)
            ?? lastSelectedRange
        if let selection = cmuxApplyFindFocusSelection(
            field: field,
            selectAll: selectAll,
            alreadyFocused: alreadyFocused,
            rememberedRange: remembered
        ) {
            lastSelectedRange = selection
            return
        }
        Task { @MainActor [weak self, weak field] in
            await Task.yield()
            guard let self, let field,
                  let selection = cmuxApplyFindFocusSelection(
                    field: field,
                    selectAll: selectAll,
                    alreadyFocused: alreadyFocused,
                    rememberedRange: remembered
                  ) else { return }
            self.lastSelectedRange = selection
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isProgrammaticMutation, let field = notification.object as? NSTextField else { return }
        configuration.onTextChanged()
        configuration.setNeedle(field.stringValue)
        rememberSelection(from: field)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        configuration.onFieldDidFocus()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField { rememberSelection(from: field) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            return handleEscape(from: textView)
        case #selector(NSResponder.insertNewline(_:)):
            guard !textView.hasMarkedText() else { return false }
            rememberSelection(from: textView)
            NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                ? configuration.onPrevious()
                : configuration.onNext()
            return true
        default:
            if cmuxFindCommandMayChangeSelection(commandSelector) {
                Task { @MainActor [weak self, weak textView] in
                    await Task.yield()
                    guard let textView else { return }
                    self?.rememberSelection(from: textView)
                }
            }
            return false
        }
    }

    private func handleEscape(from textView: NSTextView) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        rememberSelection(from: textView)
        configuration.onClose()
        return true
    }

    private func rememberSelection(from field: NSTextField) {
        if let field = field as? NativeSearchTextField,
           let selection = field.cmuxRememberSelectionFromCurrentEditor() {
            lastSelectedRange = selection
            return
        }
        guard let editor = field.currentEditor() as? NSTextView else { return }
        rememberSelection(from: editor)
    }

    private func rememberSelection(from textView: NSTextView) {
        let selection = cmuxClampedFindSelection(textView.selectedRange(), in: textView.string)
        lastSelectedRange = selection
        field.cmuxLastSelectedRange = selection
        cmuxStoreFindSelection(selection, for: configuration.selectionOwner)
    }

    private func positionBar(animated: Bool) {
        let padding: CGFloat = 8
        let size = NSSize(width: 344, height: 46)
        let origin: NSPoint
        switch corner {
        case .topLeft: origin = NSPoint(x: padding, y: padding)
        case .topRight: origin = NSPoint(x: max(padding, bounds.width - size.width - padding), y: padding)
        case .bottomLeft: origin = NSPoint(x: padding, y: max(padding, bounds.height - size.height - padding))
        case .bottomRight:
            origin = NSPoint(x: max(padding, bounds.width - size.width - padding), y: max(padding, bounds.height - size.height - padding))
        }
        let frame = NSRect(origin: origin, size: size)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bar.animator().frame = frame
            }
        } else {
            bar.frame = frame
        }
    }

    @objc private func dragBar(_ gesture: NSPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            dragStartFrame = bar.frame
        case .changed:
            let translation = gesture.translation(in: self)
            bar.frame.origin = NSPoint(x: dragStartFrame.minX + translation.x, y: dragStartFrame.minY + translation.y)
        case .ended, .cancelled:
            corner = closestCorner(to: NSPoint(x: bar.frame.midX, y: bar.frame.midY))
            positionBar(animated: true)
        default:
            break
        }
    }

    private func closestCorner(to point: NSPoint) -> Corner {
        if point.x < bounds.midX {
            return point.y < bounds.midY ? .topLeft : .bottomLeft
        }
        return point.y < bounds.midY ? .topRight : .bottomRight
    }

    @objc private func next() {
#if DEBUG
        cmuxDebugLog("\(configuration.debugScope).findbar.next id=\(configuration.identity.uuidString.prefix(5))")
#endif
        configuration.onNext()
    }

    @objc private func previous() {
#if DEBUG
        cmuxDebugLog("\(configuration.debugScope).findbar.previous id=\(configuration.identity.uuidString.prefix(5))")
#endif
        configuration.onPrevious()
    }

    @objc private func close() {
#if DEBUG
        cmuxDebugLog("\(configuration.debugScope).findbar.close id=\(configuration.identity.uuidString.prefix(5))")
#endif
        configuration.onClose()
    }
}

@MainActor
final class BrowserSearchOverlay: NativeSearchOverlayView {
    init(
        panelId: UUID,
        searchState: BrowserSearchState,
        focusRequestGeneration: UInt64,
        canApplyFocusRequest: @escaping (UInt64) -> Bool,
        onNext: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onFieldDidFocus: @escaping () -> Void
    ) {
        super.init(configuration: Self.configuration(
            panelId: panelId,
            searchState: searchState,
            focusRequestGeneration: focusRequestGeneration,
            canApplyFocusRequest: canApplyFocusRequest,
            onNext: onNext,
            onPrevious: onPrevious,
            onClose: onClose,
            onFieldDidFocus: onFieldDidFocus
        ))
        setAccessibilityIdentifier("BrowserFindSearchOverlay")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        panelId: UUID,
        searchState: BrowserSearchState,
        focusRequestGeneration: UInt64,
        canApplyFocusRequest: @escaping (UInt64) -> Bool,
        onNext: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onFieldDidFocus: @escaping () -> Void
    ) {
        update(configuration: Self.configuration(
            panelId: panelId,
            searchState: searchState,
            focusRequestGeneration: focusRequestGeneration,
            canApplyFocusRequest: canApplyFocusRequest,
            onNext: onNext,
            onPrevious: onPrevious,
            onClose: onClose,
            onFieldDidFocus: onFieldDidFocus
        ))
    }

    private static func configuration(
        panelId: UUID,
        searchState: BrowserSearchState,
        focusRequestGeneration: UInt64,
        canApplyFocusRequest: @escaping (UInt64) -> Bool,
        onNext: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onFieldDidFocus: @escaping () -> Void
    ) -> NativeSearchOverlayConfiguration {
        NativeSearchOverlayConfiguration(
            identity: panelId,
            debugScope: "browser",
            fieldAccessibilityIdentifier: "BrowserFindSearchTextField",
            selectionOwner: searchState,
            stateChanges: Publishers.CombineLatest3(searchState.$needle, searchState.$selected, searchState.$total)
                .map { _ in () }
                .eraseToAnyPublisher(),
            needle: { searchState.needle },
            setNeedle: { searchState.needle = $0 },
            selected: { searchState.selected },
            total: { searchState.total },
            focusNotificationName: .browserSearchFocus,
            matchesFocusNotification: { $0.object as? UUID == panelId },
            canApplyFocusRequest: { canApplyFocusRequest(focusRequestGeneration) },
            onNext: onNext,
            onPrevious: onPrevious,
            onClose: onClose,
            onTextChanged: {},
            onFieldDidFocus: onFieldDidFocus
        )
    }
}

@MainActor
private final class NativeSearchTextField: FindSelectionTrackingTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
