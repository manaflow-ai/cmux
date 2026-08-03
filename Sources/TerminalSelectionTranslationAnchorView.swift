#if canImport(Translation)
import AppKit
import NaturalLanguage
import Translation

/// Native anchor and popover for on-device terminal-selection translation.
@available(macOS 26.0, *)
@MainActor
final class TerminalSelectionTranslationAnchorView: NSView, NSPopoverDelegate {
    private var popover: NSPopover?
    private var contentController: TerminalSelectionTranslationViewController?
    private var onDismiss: (@MainActor () -> Void)?

    func present(text: String, onDismiss: @escaping @MainActor () -> Void) {
        self.onDismiss = onDismiss
        let controller = TerminalSelectionTranslationViewController(text: text)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 440, height: 300)
        popover.contentViewController = controller
        popover.delegate = self
        self.contentController = controller
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        contentController?.cancel()
        contentController = nil
        popover = nil
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }
}

@available(macOS 26.0, *)
@MainActor
private final class TerminalSelectionTranslationViewController: NSViewController {
    private let text: String
    private let resultView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let copyButton = NSButton()
    private var translationTask: Task<Void, Never>?

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 300))
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: String(
            localized: "terminalContextMenu.translateSelection",
            defaultValue: "Translate Selection"
        ))
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let sourceView = Self.textView(text: text, color: .secondaryLabelColor)
        let sourceScroll = Self.scrollView(documentView: sourceView)
        sourceScroll.hasVerticalScroller = true

        resultView.isEditable = false
        resultView.isSelectable = true
        resultView.drawsBackground = false
        resultView.textContainerInset = NSSize(width: 4, height: 4)
        resultView.font = .systemFont(ofSize: 13)
        let resultScroll = Self.scrollView(documentView: resultView)
        resultScroll.hasVerticalScroller = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        statusLabel.stringValue = String(
            localized: "sessionIndex.popover.loading",
            defaultValue: "Translating…"
        )
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)

        copyButton.title = String(localized: "common.copyDetails", defaultValue: "Copy Details")
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyTranslation)
        copyButton.isEnabled = false

        for child in [title, sourceScroll, resultScroll, spinner, statusLabel, copyButton] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            sourceScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            sourceScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            sourceScroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            sourceScroll.heightAnchor.constraint(equalToConstant: 80),
            resultScroll.leadingAnchor.constraint(equalTo: sourceScroll.leadingAnchor),
            resultScroll.trailingAnchor.constraint(equalTo: sourceScroll.trailingAnchor),
            resultScroll.topAnchor.constraint(equalTo: sourceScroll.bottomAnchor, constant: 8),
            resultScroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -10),
            spinner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            spinner.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            statusLabel.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            copyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startTranslation()
    }

    func cancel() {
        translationTask?.cancel()
        translationTask = nil
    }

    private func startTranslation() {
        cancel()
        let text = self.text
        translationTask = Task { @MainActor [weak self] in
            do {
                let source = Self.detectedSourceLanguage(for: text)
                let target = Self.preferredTargetLanguage(excluding: source)
                let session = TranslationSession(installedSource: source, target: target)
                let response = try await session.translate(text)
                guard !Task.isCancelled, let self else { return }
                self.resultView.string = response.targetText
                self.spinner.stopAnimation(nil)
                self.spinner.isHidden = true
                self.statusLabel.stringValue = ""
                self.copyButton.isEnabled = !response.targetText.isEmpty
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.spinner.stopAnimation(nil)
                self.spinner.isHidden = true
                self.statusLabel.stringValue = error.localizedDescription
                self.resultView.string = ""
            }
        }
    }

    private static func detectedSourceLanguage(for text: String) -> Locale.Language {
        let identifier = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"
        return Locale.Language(identifier: identifier)
    }

    private static func preferredTargetLanguage(excluding source: Locale.Language) -> Locale.Language {
        let sourceIdentifier = source.languageCode?.identifier.lowercased() ?? "en"
        if let preferred = Locale.preferredLanguages.first(where: {
            !$0.lowercased().hasPrefix(sourceIdentifier.prefix(2))
        }) {
            return Locale.Language(identifier: preferred)
        }
        return Locale.Language(identifier: sourceIdentifier.hasPrefix("en") ? "ja" : "en")
    }

    @objc private func copyTranslation() {
        let translated = resultView.string
        guard !translated.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translated, forType: .string)
    }

    private static func textView(text: String, color: NSColor) -> NSTextView {
        let view = NSTextView()
        view.string = text
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textColor = color
        view.font = .systemFont(ofSize: 12)
        view.textContainerInset = NSSize(width: 4, height: 4)
        return view
    }

    private static func scrollView(documentView: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        scroll.documentView = documentView
        return scroll
    }

    deinit {
        translationTask?.cancel()
    }
}
#endif
