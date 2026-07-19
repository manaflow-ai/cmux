import AppKit

/// The command palette's single-line native field, including event-driven
/// first-responder acquisition when its detached panel becomes key.
@MainActor
final class CommandPaletteNativeTextField: NSTextField {
    var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?

    var requestsFirstResponder = false {
        didSet {
            guard requestsFirstResponder else { return }
            requestFirstResponderIfPossible()
        }
    }

    private var didBecomeKeyObserver: (any NSObjectProtocol)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let didBecomeKeyObserver {
            NotificationCenter.default.removeObserver(didBecomeKeyObserver)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let didBecomeKeyObserver {
            NotificationCenter.default.removeObserver(didBecomeKeyObserver)
            self.didBecomeKeyObserver = nil
        }
        guard let window else { return }
        didBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.requestFirstResponderIfPossible(assumingWindowIsKey: true)
            }
        }
        requestFirstResponderIfPossible()
    }

    override func keyDown(with event: NSEvent) {
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            super.keyDown(with: event)
            return
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            return super.performKeyEquivalent(with: event)
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func requestFirstResponderIfPossible(assumingWindowIsKey: Bool = false) {
        guard requestsFirstResponder, let window else { return }
        guard assumingWindowIsKey || window.isKeyWindow else { return }
        let firstResponder = window.firstResponder
        let isAlreadyFocused = firstResponder === self
            || currentEditor() != nil
            || ((firstResponder as? NSTextView)?.delegate as? NSTextField) === self
        guard !isAlreadyFocused else { return }
        _ = window.makeFirstResponder(self)
    }
}
