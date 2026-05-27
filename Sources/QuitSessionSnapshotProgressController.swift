import AppKit

@MainActor
final class QuitSessionSnapshotProgressController: NSObject {
    private let panel: NSPanel
    private let iconBackgroundView: NSView
    private let iconView: NSImageView
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let progressLabel: NSTextField
    private let progressIndicator: NSProgressIndicator
    private let skipButton: NSButton
    private var didMarkSkipping = false

    private(set) var shouldSkipRemainingScrollback = false

    init(totalWorkspaces: Int) {
        iconBackgroundView = NSView()
        iconView = NSImageView()
        titleLabel = NSTextField(
            labelWithString: String(localized: "dialog.quitSessionSnapshot.title", defaultValue: "Saving session")
        )
        detailLabel = NSTextField(
            labelWithString: String(
                localized: "dialog.quitSessionSnapshot.message",
                defaultValue: "Saving terminal scrollback before quitting."
            )
        )
        progressLabel = NSTextField(
            labelWithString: Self.progressText(currentIndex: 0, total: totalWorkspaces)
        )
        progressIndicator = NSProgressIndicator()
        skipButton = NSButton(
            title: String(
                localized: "dialog.quitSessionSnapshot.skipRemaining",
                defaultValue: "Skip Remaining Scrollback"
            ),
            target: nil,
            action: nil
        )
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 202),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        super.init()

        panel.identifier = NSUserInterfaceItemIdentifier("cmux.quitSessionSnapshotProgress")
        panel.title = titleLabel.stringValue
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true

        iconBackgroundView.wantsLayer = true
        iconBackgroundView.layer?.cornerRadius = 12
        iconBackgroundView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .controlAccentColor
        if let symbol = NSImage(
            systemSymbolName: "clock.arrow.circlepath",
            accessibilityDescription: titleLabel.stringValue
        ) {
            iconView.image = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
            ) ?? symbol
        }

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2

        progressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        progressLabel.textColor = .tertiaryLabelColor
        progressLabel.lineBreakMode = .byTruncatingTail
        progressLabel.isHidden = totalWorkspaces == 0

        progressIndicator.style = .bar
        progressIndicator.minValue = 0
        progressIndicator.maxValue = Double(max(totalWorkspaces, 1))
        progressIndicator.doubleValue = 0
        progressIndicator.isIndeterminate = totalWorkspaces == 0

        skipButton.bezelStyle = .rounded
        skipButton.controlSize = .regular
        skipButton.isEnabled = totalWorkspaces > 0
        skipButton.target = self
        skipButton.action = #selector(skipRemainingScrollback(_:))

        let contentView = NSVisualEffectView()
        contentView.material = .windowBackground
        contentView.blendingMode = .behindWindow
        contentView.state = .active
        panel.contentView = contentView
        [iconBackgroundView, titleLabel, detailLabel, progressLabel, progressIndicator, skipButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconBackgroundView.addSubview(iconView)

        NSLayoutConstraint.activate([
            iconBackgroundView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            iconBackgroundView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            iconBackgroundView.widthAnchor.constraint(equalToConstant: 44),
            iconBackgroundView.heightAnchor.constraint(equalToConstant: 44),

            iconView.centerXAnchor.constraint(equalTo: iconBackgroundView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBackgroundView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 26),
            titleLabel.leadingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            progressIndicator.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 20),
            progressIndicator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            progressIndicator.heightAnchor.constraint(equalToConstant: 8),

            progressLabel.centerYAnchor.constraint(equalTo: skipButton.centerYAnchor),
            progressLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressLabel.trailingAnchor.constraint(lessThanOrEqualTo: skipButton.leadingAnchor, constant: -14),

            skipButton.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 16),
            skipButton.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            skipButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22),
        ])
    }

    private static func progressText(currentIndex: Int, total: Int) -> String {
        let format = String(
            localized: "dialog.quitSessionSnapshot.progressFormat",
            defaultValue: "Saving scrollback %d of %d..."
        )
        return String.localizedStringWithFormat(format, currentIndex, total)
    }

    func show(relativeTo window: NSWindow?) {
        if let window {
            panel.center()
            let windowFrame = window.frame
            var panelFrame = panel.frame
            panelFrame.origin.x = windowFrame.midX - panelFrame.width / 2
            panelFrame.origin.y = windowFrame.midY - panelFrame.height / 2
            panel.setFrame(panelFrame, display: false)
        } else {
            panel.center()
        }
        if progressIndicator.isIndeterminate {
            progressIndicator.startAnimation(nil)
        }
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
    }

    func update(currentIndex: Int, total: Int) {
        guard !shouldSkipRemainingScrollback else {
            markSkipping()
            return
        }
        let resolvedTotal = max(total, 1)
        let resolvedCurrent = min(max(currentIndex, 0), resolvedTotal)
        progressIndicator.isIndeterminate = false
        progressIndicator.maxValue = Double(resolvedTotal)
        progressIndicator.doubleValue = Double(resolvedCurrent)
        progressLabel.isHidden = false
        progressLabel.stringValue = Self.progressText(currentIndex: resolvedCurrent, total: resolvedTotal)
        panel.displayIfNeeded()
    }

    func markSkipping() {
        guard !didMarkSkipping else { return }
        didMarkSkipping = true
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        progressLabel.isHidden = false
        progressLabel.stringValue = String(
            localized: "dialog.quitSessionSnapshot.skippingRemaining",
            defaultValue: "Skipping remaining scrollback..."
        )
        panel.displayIfNeeded()
    }

    func close() {
        progressIndicator.stopAnimation(nil)
        panel.close()
    }

    @objc private func skipRemainingScrollback(_ sender: NSButton) {
        shouldSkipRemainingScrollback = true
        sender.isEnabled = false
        markSkipping()
    }
}

@MainActor
final class QuitSessionSnapshotProgressState {
    var visitedWorkspaceCount = 0
}
