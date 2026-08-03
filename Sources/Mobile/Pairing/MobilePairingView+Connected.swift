import AppKit
import CmuxFoundation

extension MobilePairingView {
    func connectedContent(_ ready: MobilePairingModel.Ready) -> NSView {
        _ = ready
        return centered([
            symbol("checkmark.circle.fill", pointSize: 36, color: .systemGreen),
            label(
                String(localized: "mobile.pairing.connected.title", defaultValue: "iPhone connected"),
                size: 17,
                weight: .semibold
            ),
            wrappingLabel(
                String(
                    localized: "mobile.pairing.connected.subtitle",
                    defaultValue: "Your terminal workspaces are now syncing to your iPhone. You can close this window."
                ),
                alignment: .center
            ),
        ])
    }

    func stepsView() -> NSView {
        let install = stepView(
            1,
            String(localized: "mobile.pairing.step.install", defaultValue: "Install cmux on your iPhone and open it.")
        )
        let prompt = label(
            String(localized: "mobile.pairing.getApp.prompt", defaultValue: "Don't have it yet?"),
            size: 11
        )
        prompt.textColor = .secondaryLabelColor
        let getApp = linkButton(
            String(localized: "mobile.pairing.getApp.link", defaultValue: "Get cmux for iPhone")
        ) { NSWorkspace.shared.open(Self.iphoneAppURL) }
        let appRow = NSStackView(views: [NSView(), prompt, getApp, NSView()])
        appRow.orientation = .horizontal
        appRow.alignment = .firstBaseline
        appRow.spacing = 4
        let signIn = stepView(
            2,
            String(localized: "mobile.pairing.step.signIn", defaultValue: "Sign in with the same account you use on this Mac.")
        )
        let scan = stepView(
            3,
            String(localized: "mobile.pairing.step.scan", defaultValue: "Tap Add device, then Scan QR Code, and point the camera at the code above.")
        )
        let stack = vertical([install, appRow, signIn, scan], alignment: .leading, spacing: 10)
        for row in [install, appRow, signIn, scan] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    func stepView(_ number: Int, _ text: String) -> NSView {
        let badge = label(String(number), size: 11, weight: .bold)
        badge.alignment = .center
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.layer?.cornerRadius = 10
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 20),
            badge.heightAnchor.constraint(equalToConstant: 20),
        ])
        let body = wrappingLabel(text)
        body.textColor = .labelColor
        body.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [badge, body])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        return row
    }

    func manualFallback(_ ready: MobilePairingModel.Ready) -> NSView {
        let title = label(
            String(localized: "mobile.pairing.manual.title", defaultValue: "Can't scan? Add this Mac manually:"),
            size: 11,
            weight: .semibold
        )
        title.textColor = .secondaryLabelColor
        var views: [NSView] = [title]
        for line in ready.tailscaleLines {
            let route = label(line, size: 11)
            route.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            route.textColor = .secondaryLabelColor
            route.isSelectable = true
            views.append(route)
        }
        if let entry = ready.manualEntry {
            let buttons = NSStackView(views: [
                copyButton(
                    label: String(localized: "mobile.pairing.manual.copyIP", defaultValue: "Copy IP"),
                    value: entry.host
                ),
                copyButton(
                    label: String(localized: "mobile.pairing.manual.copyPort", defaultValue: "Copy Port"),
                    value: String(entry.port)
                ),
            ])
            buttons.orientation = .horizontal
            buttons.alignment = .centerY
            buttons.spacing = 8
            views.append(buttons)
        }

        let stack = vertical(views, alignment: .leading, spacing: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let card = MobilePairingCardView(frame: .zero)
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
        return card
    }

    func copyButton(label title: String, value: String) -> NSButton {
        let copied = copiedValue == value
        let title = copied
            ? String(localized: "mobile.pairing.manual.copied", defaultValue: "Copied")
            : title
        let button = button(title) { [weak self] in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            self?.flashCopied(value)
        }
        button.controlSize = .small
        button.font = GlobalFontMagnification.systemFont(ofSize: 11)
        button.image = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        return button
    }

    func flashCopied(_ value: String) {
        copiedValueGeneration &+= 1
        let generation = copiedValueGeneration
        copiedValue = value
        rerender()
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { @MainActor [weak self] in
            try? await ContinuousClock().sleep(for: .seconds(1.6))
            guard !Task.isCancelled,
                  let self,
                  copiedValueGeneration == generation else { return }
            copiedValue = nil
            rerender()
        }
    }
}

private final class MobilePairingCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        refreshColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColor()
    }

    private func refreshColor() {
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08).cgColor
    }
}
