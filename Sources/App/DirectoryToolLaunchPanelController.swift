import AppKit

final class DirectoryToolLaunchPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let spinner: NSProgressIndicator
    private let messageLabel: NSTextField
    private let outputTextView: NSTextView
    private let allowButton: NSButton
    private let stopButton: NSButton
    private let noOutputText: String
    private let launchingMessage: String
    private let launchingOutputText: String
    private let onAllow: ((DirectoryToolLaunchPanelController) -> Void)?
    private let onStop: () -> Void
    private var isClosed = false
    private var didAllow = false

    init(
        title: String,
        initialMessage: String,
        launchingMessage: String,
        initialOutput: String,
        requiresApproval: Bool,
        onAllow: ((DirectoryToolLaunchPanelController) -> Void)?,
        onStop: @escaping () -> Void
    ) {
        self.launchingMessage = launchingMessage
        self.onAllow = onAllow
        self.onStop = onStop
        noOutputText = String(
            localized: "directoryTool.launchProgress.noOutput",
            defaultValue: "No output yet."
        )
        launchingOutputText = String(
            localized: "directoryTool.launchProgress.launching",
            defaultValue: "Launching..."
        )

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 256))

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.isHidden = requiresApproval
        if !requiresApproval {
            spinner.startAnimation(nil)
        }

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        messageLabel = NSTextField(labelWithString: initialMessage)
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2

        let headerStack = NSStackView(views: [spinner, titleLabel])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 10

        outputTextView = NSTextView()
        outputTextView.isEditable = false
        outputTextView.isSelectable = true
        outputTextView.drawsBackground = false
        outputTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        outputTextView.textColor = .secondaryLabelColor
        outputTextView.textContainerInset = NSSize(width: 8, height: 8)
        outputTextView.string = initialOutput

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor.withAlphaComponent(0.65)
        scrollView.borderType = .lineBorder
        scrollView.documentView = outputTextView

        allowButton = NSButton(title: String(
            localized: "directoryTool.launchProgress.allow",
            defaultValue: "Allow"
        ), target: nil, action: nil)
        allowButton.bezelStyle = .rounded
        allowButton.keyEquivalent = "\r"
        allowButton.isHidden = !requiresApproval

        let stopButtonTitle: String
        if requiresApproval {
            stopButtonTitle = String(
                localized: "directoryTool.launchProgress.cancel",
                defaultValue: "Cancel"
            )
        } else {
            stopButtonTitle = String(
                localized: "directoryTool.launchProgress.stop",
                defaultValue: "Stop"
            )
        }
        stopButton = NSButton(title: stopButtonTitle, target: nil, action: nil)
        stopButton.bezelStyle = .rounded

        let footerStack = NSStackView(views: [NSView(), stopButton, allowButton])
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 8

        let stack = NSStackView(views: [headerStack, messageLabel, scrollView, footerStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            spinner.widthAnchor.constraint(equalToConstant: 18),
            spinner.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 128)
        ])

        panel = NSPanel(
            contentRect: contentView.frame,
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.contentView = contentView
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        super.init()

        panel.delegate = self
        allowButton.target = self
        allowButton.action = #selector(allow)
        stopButton.target = self
        stopButton.action = #selector(stop)
    }

    static func startingTitle(displayName: String) -> String {
        let titleFormat = String(
            localized: "directoryTool.launchProgress.title",
            defaultValue: "Starting %@"
        )
        return String(format: titleFormat, displayName)
    }

    static func commandPreview(command: String, directoryURL: URL) -> String {
        """
        cd \(directoryURL.path)
        \(command)
        """
    }

    func show(presentingWindow: NSWindow?) {
        guard !isClosed else { return }
        if let presentingWindow {
            let windowFrame = presentingWindow.frame
            let panelFrame = panel.frame
            let origin = NSPoint(
                x: windowFrame.midX - panelFrame.width / 2,
                y: windowFrame.maxY - panelFrame.height - 72
            )
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
    }

    func updateOutput(_ output: String) {
        guard !isClosed else { return }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        outputTextView.string = trimmed.isEmpty ? noOutputText : trimmed
        outputTextView.scrollToEndOfDocument(nil)
    }

    func finish(message: String, stopTitle: String? = nil) {
        guard !isClosed else { return }
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        messageLabel.stringValue = message
        allowButton.isHidden = true
        if let stopTitle {
            stopButton.title = stopTitle
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        if !isClosed {
            onStop()
        }
        isClosed = true
    }

    @objc private func allow() {
        guard !didAllow, !isClosed else { return }
        didAllow = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        messageLabel.stringValue = launchingMessage
        outputTextView.string = launchingOutputText
        allowButton.isHidden = true
        stopButton.title = String(
            localized: "directoryTool.launchProgress.stop",
            defaultValue: "Stop"
        )
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        onAllow?(self)
    }

    @objc private func stop() {
        stopButton.isEnabled = false
        onStop()
        close()
    }
}
