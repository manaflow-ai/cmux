import AppKit
import SwiftUI

/// Presents a fresh nonmodal computer-use onboarding window for each run.
@MainActor
final class ComputerUseOnboardingWindowController {
    static let seenDefaultsKey = "cmux.computerUse.onboarding.seen"

    private var window: NSWindow?
    private let permissionService: ComputerUsePermissionService
    private let agentSessionRequiresRestart: @MainActor () -> Bool

    init() {
        self.permissionService = ComputerUsePermissionService()
        self.agentSessionRequiresRestart = { false }
    }

    init(
        permissionService: ComputerUsePermissionService,
        agentSessionRequiresRestart: @escaping @MainActor () -> Bool = { false }
    ) {
        self.permissionService = permissionService
        self.agentSessionRequiresRestart = agentSessionRequiresRestart
    }

    static func shouldPresentAutomatically(
        seen: Bool,
        featureEnabled: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool
    ) -> Bool {
        // Surface whenever a required permission is missing — NOT gated on `seen`.
        // A dev rebuild changes the app's code signature, so macOS drops the
        // prior TCC grant and permissions go missing again; gating on `seen`
        // meant onboarding never re-appeared to help the user re-grant. When both
        // permissions are already granted this is false, so a fully-set-up user
        // is never nagged. `seen` still suppresses the pure first-run intro only
        // when nothing is missing (handled by the caller's step selection).
        _ = seen
        return featureEnabled && !(accessibilityGranted && screenRecordingGranted)
    }

    func present() {
        window?.close()
        let window = makeWindow()
        self.window = window
        // A dev/background-launched app does not reliably steal focus, so a
        // normal-level window opens buried behind whatever is frontmost and the
        // user never sees the setup prompt. Keep it floating above other apps and
        // on the active Space for the whole presentation so it is always visible
        // when permissions are missing; it closes when the user finishes or skips.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .moveToActiveSpace]
        window.hidesOnDeactivate = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func makeWindow() -> NSWindow {
        let rootView = ComputerUseOnboardingView(
            permissionService: permissionService,
            agentSessionRequiresRestart: agentSessionRequiresRestart,
            onClose: { [weak self] in self?.window?.close() }
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "computerUse.onboarding.windowTitle", defaultValue: "Computer Use Setup")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

/// A pure-AppKit popup that presents the STANDALONE computer-use helper as a
/// large draggable tile plus buttons that open the Accessibility / Screen
/// Recording panes. The user drags the tile straight into the permission list to
/// add the helper, then flips it on — the "just works" flow the user asked for.
///
/// Built entirely in AppKit — no SwiftUI, no settings bindings — precisely so it
/// is safe to present while a computer-use session is spinning up. The full
/// SwiftUI onboarding window could not be auto-presented there: it hit a
/// SwiftUI/settings main-actor concurrency crash on macOS 26.x. This panel has
/// no such dependency, so it can appear the moment the agent reaches for
/// computer use and a grant is missing.
@MainActor
final class ComputerUseHelperDragWindowController: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private let permissionService: ComputerUsePermissionService
    private var pollTimer: Timer?
    private weak var accessibilityDot: NSView?
    private weak var screenRecordingDot: NSView?
    private weak var accessibilityLabel: NSTextField?
    private weak var screenRecordingLabel: NSTextField?

    init(permissionService: ComputerUsePermissionService) {
        self.permissionService = permissionService
        super.init()
    }

    deinit {
        pollTimer?.invalidate()
    }

    /// Whether the drag popup is currently on screen, so callers can avoid
    /// re-presenting (which would steal focus) while it is already visible.
    var isVisible: Bool { window?.isVisible ?? false }

    /// Present the drag popup. Installs the standalone helper first so the tile
    /// drags the exact bundle the daemon runs (and the one the user must grant).
    func present() {
        let helperURL = permissionService.ensureStandaloneHelperInstalled()
        window?.close()
        let panel = makePanel(helperURL: helperURL)
        window = panel
        panel.delegate = self
        // Dev/background-launched apps don't reliably steal focus; keep the panel
        // floating above other apps and on the active Space so it's always
        // visible while a permission is missing.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .moveToActiveSpace]
        panel.hidesOnDeactivate = false
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        startPolling()
        refreshStatus()
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startPolling() {
        pollTimer?.invalidate()
        // Poll the helper's TCC status so the dots flip to green and the panel
        // auto-closes the moment both grants land — no manual refresh needed.
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func refreshStatus() {
        Task { [weak self] in
            guard let self else { return }
            let status = await permissionService.refreshHelperStatus()
            apply(accessibility: status.accessibility, screenRecording: status.screenRecording)
        }
    }

    private func apply(accessibility: Bool, screenRecording: Bool) {
        setDot(accessibilityDot, granted: accessibility)
        setDot(screenRecordingDot, granted: screenRecording)
        accessibilityLabel?.stringValue = statusText(
            prefix: String(localized: "computerUse.dragPopup.accessibility", defaultValue: "Accessibility"),
            granted: accessibility
        )
        screenRecordingLabel?.stringValue = statusText(
            prefix: String(localized: "computerUse.dragPopup.screenRecording", defaultValue: "Screen Recording"),
            granted: screenRecording
        )
        if accessibility && screenRecording {
            // Both granted — close shortly so the user sees the green state.
            pollTimer?.invalidate()
            pollTimer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.window?.close()
            }
        }
    }

    private func statusText(prefix: String, granted: Bool) -> String {
        let state = granted
            ? String(localized: "computerUse.dragPopup.granted", defaultValue: "granted")
            : String(localized: "computerUse.dragPopup.notGranted", defaultValue: "not granted")
        return "\(prefix): \(state)"
    }

    private func setDot(_ dot: NSView?, granted: Bool) {
        dot?.layer?.backgroundColor = (granted ? NSColor.systemGreen : NSColor.systemOrange).cgColor
    }

    private func makePanel(helperURL: URL?) -> NSPanel {
        let helperName = permissionService.helperDisplayName

        let title = NSTextField(labelWithString: String(
            localized: "computerUse.dragPopup.title",
            defaultValue: "Enable \(helperName)"
        ))
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString: String(
            localized: "computerUse.dragPopup.subtitle",
            defaultValue: "Drag the icon below into the list in System Settings, then turn it on. This grants the helper — not cmux — permission to control this Mac."
        ))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 380

        let tile = HelperDragTileView(fileURL: helperURL, helperName: helperName)
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.widthAnchor.constraint(equalToConstant: 380).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 108).isActive = true

        let openAX = NSButton(
            title: String(localized: "computerUse.dragPopup.openAccessibility", defaultValue: "Open Accessibility Settings"),
            target: self, action: #selector(openAccessibility)
        )
        openAX.bezelStyle = .rounded
        let openSR = NSButton(
            title: String(localized: "computerUse.dragPopup.openScreenRecording", defaultValue: "Open Screen Recording Settings"),
            target: self, action: #selector(openScreenRecording)
        )
        openSR.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [openAX, openSR])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let (axRow, axDot, axLabel) = makeStatusRow(
            prefix: String(localized: "computerUse.dragPopup.accessibility", defaultValue: "Accessibility")
        )
        let (srRow, srDot, srLabel) = makeStatusRow(
            prefix: String(localized: "computerUse.dragPopup.screenRecording", defaultValue: "Screen Recording")
        )
        accessibilityDot = axDot
        screenRecordingDot = srDot
        accessibilityLabel = axLabel
        screenRecordingLabel = srLabel

        let done = NSButton(
            title: String(localized: "computerUse.dragPopup.done", defaultValue: "Done"),
            target: self, action: #selector(closePanel)
        )
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let doneRow = NSStackView(views: [NSView(), done])
        doneRow.orientation = .horizontal
        doneRow.distribution = .fill

        let stack = NSStackView(views: [title, subtitle, tile, buttonRow, axRow, srRow, doneRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 428, height: 380),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "computerUse.dragPopup.windowTitle", defaultValue: "\(helperName) Setup")
        panel.contentView = content
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.center()
        return panel
    }

    private func makeStatusRow(prefix: String) -> (NSStackView, NSView, NSTextField) {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        let label = NSTextField(labelWithString: statusText(prefix: prefix, granted: false))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [dot, label])
        row.orientation = .horizontal
        row.spacing = 8
        return (row, dot, label)
    }

    @objc private func openAccessibility() {
        permissionService.openAccessibilitySettings()
        permissionService.revealHelperInFinder()
    }

    @objc private func openScreenRecording() {
        permissionService.openScreenRecordingSettings()
        permissionService.revealHelperInFinder()
    }

    @objc private func closePanel() {
        window?.close()
    }
}

/// A large icon well that is a drag SOURCE for the helper's `.app` file URL.
/// Dragging it into a System Settings permission list adds the helper. Pure
/// AppKit so it composes into the crash-safe drag popup above.
@MainActor
private final class HelperDragTileView: NSView, NSDraggingSource {
    private let fileURL: URL?
    private let iconView = NSImageView()

    init(fileURL: URL?, helperName: String) {
        self.fileURL = fileURL
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        iconView.imageScaling = .scaleProportionallyUpOrDown
        if let fileURL {
            iconView.image = NSWorkspace.shared.icon(forFile: fileURL.path)
        } else {
            iconView.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: helperName)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        let hint = NSTextField(labelWithString: String(
            localized: "computerUse.dragPopup.tileHint",
            defaultValue: "Drag me into the list →"
        ))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let textStack = NSStackView(views: [name, hint])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(textStack)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 60),
            iconView.heightAnchor.constraint(equalToConstant: 60),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        guard let fileURL else { return }
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        let dragImage = iconView.image ?? NSImage()
        item.setDraggingFrame(iconView.frame, contents: dragImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }
}
