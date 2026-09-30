import AppKit
import CmuxSettings
import ImageIO
import UniformTypeIdentifiers

extension GhosttyNSView {
    func recordDirectAgentHibernationTerminalInput() {
        guard let terminalSurface else { return }
        GhosttyApp.terminalSurfaceRuntimeDependencies
            .hibernationRecorder.recordTerminalInput(
                workspaceId: terminalSurface.tabId,
                panelId: terminalSurface.id
            )
    }

    @IBAction func paste(_ sender: Any?) {
        guard prepareSurfaceForPaste(reason: "paste.missingSurface") else {
            return
        }
        recordDirectAgentHibernationTerminalInput()
        showTerminalImagePastePreviewIfNeeded()
        if sendAgentImagePasteKeyIfEnabled() {
            return
        }
        if performBindingAction("paste_from_clipboard") {
            terminalSurface?.didAcceptExplicitInput()
        }
    }

    /// Shows a cmux-owned preview for an image-only paste before the terminal
    /// or an agent consumes it. Codex and Claude Code intentionally put a
    /// textual `[Image #N]` token in their TUI composers; this overlay gives
    /// the user a real preview without changing the bytes delivered to the
    /// foreground process.
    private func showTerminalImagePastePreviewIfNeeded() {
        guard let terminalSurface,
              let pasteboard = GhosttyApp.terminalPasteboard.pasteboard(
                for: GHOSTTY_CLIPBOARD_STANDARD
              ),
              TerminalAgentImagePasteRouting.clipboardHoldsOnlyImageData(
                pasteboard.types ?? []
              ) else {
            return
        }

        let surfaceID = terminalSurface.id
        let pasteboardName = pasteboard.name.rawValue
        let pasteboardChangeCount = pasteboard.changeCount
        let imageTypes = (pasteboard.types ?? []).map(\.rawValue)
        Task.detached(priority: .userInitiated) { [weak self] in
            let sourcePasteboard = NSPasteboard(
                name: NSPasteboard.Name(rawValue: pasteboardName)
            )
            guard sourcePasteboard.changeCount == pasteboardChangeCount else { return }
            let data = Self.imageData(
                from: sourcePasteboard,
                types: imageTypes
            )
            guard let data,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return
            }
            let size = NSSize(width: image.width, height: image.height)
            await MainActor.run { [weak self] in
                guard let self,
                      self.terminalSurface?.id == surfaceID else { return }
                self.terminalSurface?.hostedView.showTerminalImagePastePreview(
                    NSImage(cgImage: image, size: size)
                )
            }
        }
    }

    private static func imageData(
        from pasteboard: NSPasteboard,
        types: [String]
    ) -> Data? {
        let preferredTypes = [
            UTType.png.identifier,
            UTType.jpeg.identifier,
            UTType.tiff.identifier,
            UTType.gif.identifier,
            UTType.heic.identifier,
            UTType.heif.identifier,
        ]
        for rawType in preferredTypes where types.contains(rawType) {
            if let data = pasteboard.data(
                forType: NSPasteboard.PasteboardType(rawValue: rawType)
            ) {
                return data
            }
        }
        for rawType in types {
            if let data = pasteboard.data(
                forType: NSPasteboard.PasteboardType(rawValue: rawType)
            ) {
                return data
            }
        }
        return nil
    }

    /// With `terminal.agentImagePasteSendsCtrlV` on, sends Ctrl+V instead of
    /// pasting when Claude Code or Codex runs in this local pane and the
    /// clipboard holds only an image, so the agent attaches the image itself.
    /// Returns false, leaving the regular paste to run, in every other case,
    /// including when the key could not be delivered.
    private func sendAgentImagePasteKeyIfEnabled() -> Bool {
        let isEnabled = TerminalCatalogSection()
            .agentImagePasteSendsCtrlV.value(in: .standard)
        guard isEnabled,
              let terminalSurface,
              let workspace = terminalSurface.owningWorkspace(),
              let panel = workspace.panels[terminalSurface.id] as? TerminalPanel,
              !panel.isAgentHibernated else {
            return false
        }
        let shouldSend = TerminalAgentImagePasteRouting.shouldSendAgentPasteKey(
            isEnabled: isEnabled,
            workspace: workspace,
            panel: panel,
            pasteboardTypes: { NSPasteboard.general.types ?? [] },
            foregroundProcessGroupID: { terminalSurface.foregroundProcessID() },
            resolveTarget: {
                terminalSurface.resolvedImageTransferTarget(mode: .paste, in: workspace)
            }
        )
        guard shouldSend else { return false }
        let delivered = panel.sendNamedKey(TerminalAgentImagePasteRouting.agentPasteKeyName)
#if DEBUG
        cmuxDebugLog(
            "terminal.agentImagePaste.ctrlV surface=\(terminalSurface.id.uuidString.prefix(5)) " +
            "delivered=\(delivered ? 1 : 0)"
        )
#endif
        return delivered
    }

    /// Pastes clipboard text as plain text, stripping any rich formatting.
    @IBAction func pasteAsPlainText(_ sender: Any?) {
        guard prepareSurfaceForPaste(
            reason: "pasteAsPlainText.missingSurface"
        ) else {
            return
        }
        recordDirectAgentHibernationTerminalInput()
        if performBindingAction("paste_from_clipboard") {
            terminalSurface?.didAcceptExplicitInput()
        }
    }
}

// MARK: - Terminal image paste preview

/// A small, clickable image card that floats inside the terminal pane. It is
/// deliberately an AppKit overlay rather than terminal output, so scrollback,
/// selection, and the agent's own `[Image #N]` placeholder remain untouched.
private final class TerminalImagePastePreviewCard: NSView {
    private let materialView = NSVisualEffectView(frame: .zero)
    private let imageView = NSImageView(frame: .zero)
    private let closeButton = NSButton(frame: .zero)

    var onExpand: (() -> Void)?
    var onDismiss: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        materialView.material = .popover
        materialView.blendingMode = .withinWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = 10
        materialView.layer?.masksToBounds = true
        addSubview(materialView)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.isEditable = false
        let previewLabel = String(
            localized: "terminal.imagePastePreview.accessibility",
            defaultValue: "Pasted image preview"
        )
        imageView.setAccessibilityLabel(previewLabel)
        materialView.addSubview(imageView)

        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: String(localized: "common.close", defaultValue: "Close")
        )
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        closeButton.toolTip = String(localized: "common.close", defaultValue: "Close")
        closeButton.setAccessibilityLabel(
            String(localized: "common.close", defaultValue: "Close")
        )
        closeButton.target = self
        closeButton.action = #selector(dismissPreview)
        materialView.addSubview(closeButton)

        setAccessibilityRole(.group)
        setAccessibilityLabel(previewLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: NSImage) {
        imageView.image = image
        needsLayout = true
    }

    override func layout() {
        super.layout()
        materialView.frame = bounds
        imageView.frame = bounds.insetBy(dx: 8, dy: 8)
        let buttonSize: CGFloat = 22
        closeButton.frame = NSRect(
            x: bounds.maxX - buttonSize - 4,
            y: bounds.maxY - buttonSize - 4,
            width: buttonSize,
            height: buttonSize
        )
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if imageView.frame.contains(point) {
            onExpand?()
        } else {
            super.mouseUp(with: event)
        }
    }

    @objc private func dismissPreview() {
        onDismiss?()
    }
}

final class TerminalImagePastePreviewController {
    private weak var host: GhosttySurfaceScrollView?
    private let card = TerminalImagePastePreviewCard()
    private var image: NSImage?
    private var popover: NSPopover?

    init(host: GhosttySurfaceScrollView) {
        self.host = host
        card.isHidden = true
        card.onExpand = { [weak self] in self?.showExpandedPreview() }
        card.onDismiss = { [weak self] in self?.dismiss() }
    }

    func show(image: NSImage) {
        self.image = image
        card.setImage(image)
        guard let host else { return }
        if card.superview !== host {
            host.addSubview(card, positioned: .above, relativeTo: nil)
        }
        card.isHidden = false
        updateLayout()
    }

    func updateLayout() {
        guard let host, !card.isHidden, let image else { return }
        let size = Self.cardSize(for: image.size, in: host.bounds.size)
        let cursorRect = host.surfaceView.inputCursorRectInHostedView()
        let horizontalMargin: CGFloat = 10
        let verticalMargin: CGFloat = 8
        let preferredX = cursorRect?.minX ?? horizontalMargin
        let x = min(
            max(horizontalMargin, preferredX),
            max(horizontalMargin, host.bounds.width - size.width - horizontalMargin)
        )
        let preferredY = (cursorRect?.maxY ?? verticalMargin) + verticalMargin
        let y: CGFloat
        if preferredY + size.height <= host.bounds.height - verticalMargin {
            y = preferredY
        } else {
            y = max(
                verticalMargin,
                (cursorRect?.minY ?? verticalMargin) - size.height - verticalMargin
            )
        }
        card.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    func dismiss() {
        popover?.close()
        popover = nil
        image = nil
        card.isHidden = true
    }

    private func showExpandedPreview() {
        guard let image, let host else { return }
        let size = Self.expandedSize(for: image.size, in: host.bounds.size)
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter

        let content = NSViewController()
        content.view = imageView
        let nextPopover = NSPopover()
        nextPopover.behavior = .transient
        nextPopover.animates = true
        nextPopover.contentViewController = content
        nextPopover.contentSize = size
        nextPopover.show(
            relativeTo: card.bounds,
            of: card,
            preferredEdge: .maxY
        )
        popover?.close()
        popover = nextPopover
    }

    private static func cardSize(for imageSize: NSSize, in hostSize: NSSize) -> NSSize {
        fittedSize(
            imageSize,
            maxSize: NSSize(
                width: min(280, max(160, hostSize.width * 0.32)),
                height: min(190, max(110, hostSize.height * 0.28))
            )
        )
    }

    private static func expandedSize(for imageSize: NSSize, in hostSize: NSSize) -> NSSize {
        fittedSize(
            imageSize,
            maxSize: NSSize(
                width: min(760, max(320, hostSize.width * 0.75)),
                height: min(620, max(240, hostSize.height * 0.72))
            )
        )
    }

    private static func fittedSize(_ imageSize: NSSize, maxSize: NSSize) -> NSSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return maxSize }
        let scale = min(
            maxSize.width / imageSize.width,
            maxSize.height / imageSize.height,
            1
        )
        return NSSize(
            width: max(1, floor(imageSize.width * scale)),
            height: max(1, floor(imageSize.height * scale))
        )
    }
}

private extension GhosttyNSView {
    func inputCursorRectInHostedView() -> NSRect? {
        guard let window, let host = terminalSurface?.hostedView else { return nil }
        let screenRect = firstRect(
            forCharacterRange: selectedRange(),
            actualRange: nil
        )
        guard !screenRect.isEmpty else { return nil }
        let windowRect = window.convertFromScreen(screenRect)
        return host.convert(windowRect, from: nil)
    }
}

private extension GhosttySurfaceScrollView {
    func showTerminalImagePastePreview(_ image: NSImage) {
        terminalImagePastePreviewController.show(image: image)
    }
}
