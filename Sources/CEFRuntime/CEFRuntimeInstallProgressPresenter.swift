import AppKit

@MainActor
final class CEFRuntimeInstallProgressPresenter {
    private weak var presentingWindow: NSWindow?
    private let window: NSWindow
    private let titleField: NSTextField
    private let detailField: NSTextField
    private let progressIndicator: NSProgressIndicator

    init(presentingWindow: NSWindow?) {
        self.presentingWindow = presentingWindow

        titleField = NSTextField(labelWithString: String(
            localized: "cefRuntime.progress.title",
            defaultValue: "Installing Chromium runtime"
        ))
        titleField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleField.lineBreakMode = .byWordWrapping

        detailField = NSTextField(labelWithString: String(
            localized: "cefRuntime.progress.preparing",
            defaultValue: "Preparing download..."
        ))
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byWordWrapping

        progressIndicator = NSProgressIndicator()
        progressIndicator.isIndeterminate = true
        progressIndicator.style = .bar
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.controlSize = .regular

        let stack = NSStackView(views: [titleField, detailField, progressIndicator])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 380),
            progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "cefRuntime.progress.windowTitle", defaultValue: "Chromium Runtime")
        window.contentView = contentView
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.cefRuntime.installProgress")
    }

    func show() {
        progressIndicator.startAnimation(nil)
        if let presentingWindow {
            presentingWindow.beginSheet(window, completionHandler: nil)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func update(phase: CEFRuntimeInstallPhase) {
        switch phase {
        case .downloading(let progress):
            titleField.stringValue = String(
                localized: "cefRuntime.progress.downloadingTitle",
                defaultValue: "Downloading Chromium runtime"
            )
            if let progress {
                progressIndicator.stopAnimation(nil)
                progressIndicator.isIndeterminate = false
                progressIndicator.doubleValue = min(max(progress, 0), 1) * 100
                detailField.stringValue = String(
                    format: String(localized: "cefRuntime.progress.downloadingPercent", defaultValue: "%.0f%% downloaded"),
                    min(max(progress, 0), 1) * 100
                )
            } else {
                progressIndicator.isIndeterminate = true
                progressIndicator.startAnimation(nil)
                detailField.stringValue = String(
                    localized: "cefRuntime.progress.downloading",
                    defaultValue: "Starting download..."
                )
            }
        case .installing:
            titleField.stringValue = String(
                localized: "cefRuntime.progress.installingTitle",
                defaultValue: "Installing Chromium runtime"
            )
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
            detailField.stringValue = String(
                localized: "cefRuntime.progress.installing",
                defaultValue: "Verifying and installing files..."
            )
        case .idle, .installed, .failed:
            break
        }
    }

    func close() {
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        } else {
            window.close()
        }
    }
}
