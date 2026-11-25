import AppKit
import CmuxNextUiLayerPreview
import Foundation
import Observation
import SwiftUI

// The host as a small desktop app: real draggable windows that wear the installed cmux NEXT's
// theme and background (UiLayerAppLook), at several sizes at once, and that can animate on their
// own. No Ghostty, daemon, Chromium or app composition root: only the real leaf views.

@main
@MainActor
struct UiLayerHostMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = UiLayerHostDelegate(arguments: CommandLine.arguments)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// `--sizes`, `--animate`, `--cycle-sizes` and `--no-app-look`; `--snapshot` and `--attach` are
/// ``UiLayerSource``'s.
struct UiLayerHostOptions: Equatable {
    /// The window sizes to open at launch, one window each.
    var sizes: [CGSize] = [UiLayerHostOptions.defaultSize]
    var animate = false
    var cycleSizes = false
    var followsAppLook = true

    static let defaultSize = CGSize(width: 1_120, height: 720)
    /// `--sizes all` and Open All Sizes: a 14" MacBook Pro's window, the default, a half-screen
    /// split and a narrow one.
    static let allSizes = [CGSize(width: 1_512, height: 982), defaultSize, CGSize(width: 760, height: 560),
                           CGSize(width: 520, height: 420)]

    static func parse(arguments: [String]) -> Self {
        var options = Self()
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--sizes" where index + 1 < arguments.count:
                let value = arguments[index + 1]
                let sizes = value == "all" ? allSizes : value.split(separator: ",").compactMap { size(String($0)) }
                if !sizes.isEmpty { options.sizes = sizes }
                index += 2
            case "--animate":
                options.animate = true
                index += 1
            case "--cycle-sizes":
                options.cycleSizes = true
                index += 1
            case "--no-app-look":
                options.followsAppLook = false
                index += 1
            default:
                index += 1
            }
        }
        return options
    }

    /// `1470x956`, within 320x240...5120x2880; nil for anything else.
    static func size(_ text: String) -> CGSize? {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
        return CGSize(width: min(max(width, 320), 5_120), height: min(max(height, 240), 2_880))
    }
}

/// The installed app's look, applied to the app scope and reapplied when one of its files is
/// saved or the system switches between light and dark.
@MainActor
@Observable
final class UiLayerLookModel {
    /// Why the look could not be read in full; nil when it was.
    private(set) var problem: String?
    @ObservationIgnored private let enabled: Bool
    @ObservationIgnored private var watchers: [ProjectionFileWatcher] = []
    @ObservationIgnored private var appearanceObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var generation: UInt64 = 0

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func start() {
        guard enabled else { return }
        reload()
        watchers = UiLayerAppLook.watchedFiles().compactMap { url in
            ProjectionFileWatcher(url: url) { Task { @MainActor [weak self] in self?.reload() } }
        }
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in Task { @MainActor [weak self] in self?.reload() } }
    }

    func reload() {
        guard enabled else { return }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        generation &+= 1
        let current = generation
        Task { [weak self] in
            let look = await UiLayerAppLook.loadInBackground(isDark: isDark)
            // A later save or appearance switch supersedes this read.
            guard let self, self.generation == current else { return }
            look.applyToApp()
            self.problem = look.themeName == nil ? "No theme file found for the app's theme; showing Ghostty's colors" : nil
        }
    }
}

/// Plays the windows on their own: every beat the next workspace and tab, the unread dot, and a
/// message typed into the composer.
@MainActor
@Observable
final class UiLayerAnimator {
    private(set) var isRunning = false
    private(set) var beat = 0
    private(set) var typed = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    static let phrase = "Make the sidebar breathe at every size"
    static let beatLength: Duration = .milliseconds(1_600)
    static let keyLength: Duration = .milliseconds(45)

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                for count in 0...Self.phrase.count {
                    self?.typed = count
                    try? await Task.sleep(for: Self.keyLength)
                    if Task.isCancelled { return }
                }
                try? await Task.sleep(for: Self.beatLength)
                self?.beat += 1
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// What the windows show on this beat; nil without workspaces.
    func frame(of snapshot: ProjectionSnapshot) -> UiLayerPreviewData? {
        let workspaces = snapshot.workspaces
        guard !workspaces.isEmpty else { return nil }
        let workspace = workspaces[beat % workspaces.count]
        let tab = workspace.tabs.isEmpty ? nil : workspace.tabs[(beat / workspaces.count) % workspace.tabs.count]
        return UiLayerPreviewData(
            workspaceName: workspace.name,
            tabTitle: tab?.title ?? "No tab",
            tabSubtitle: tab?.subtitle,
            composerPlaceholder: String(Self.phrase.prefix(typed)),
            unread: beat % 2 == 0
        )
    }
}

@MainActor
final class UiLayerHostDelegate: NSObject, NSApplicationDelegate {
    private let options: UiLayerHostOptions
    private let projection: ProjectionModel
    private let animator = UiLayerAnimator()
    private let look: UiLayerLookModel
    private var controlServer: UiLayerControlServer?
    private var windows: [NSWindow] = []
    private var cycleTask: Task<Void, Never>?
    private var cycleItem: NSMenuItem?
    private var animateItem: NSMenuItem?

    init(arguments: [String]) {
        options = UiLayerHostOptions.parse(arguments: arguments)
        projection = ProjectionModel(arguments: arguments)
        look = UiLayerLookModel(enabled: options.followsAppLook)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Never claim cmux's live control socket. Capture tooling opts in to
        // this host-only seam with its separate path.
        controlServer = UiLayerControlServer(socketPath: ProcessInfo.processInfo.environment["CMUX_UI_LAYER_CONTROL_SOCKET"])
        controlServer?.start()
        look.start()
        NSApp.mainMenu = makeMenu()
        for size in options.sizes { openWindow(size: size) }
        if options.animate { toggleAnimation() }
        if options.cycleSizes { toggleCycleSizes() }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func openWindow(size: CGSize) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "cmux UI layer \(Int(size.width))×\(Int(size.height))"
        window.installUiLayerContent(NSHostingView(rootView: UiLayerView(projection: projection, animator: animator, look: look)))
        if let last = windows.last(where: \.isVisible) {
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 32, y: last.frame.maxY - 32))
        } else {
            window.center()
        }
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func newWindow(_ sender: Any?) {
        openWindow(size: NSApp.keyWindow?.frame.size ?? UiLayerHostOptions.defaultSize)
    }

    @objc private func openAllSizes(_ sender: Any?) {
        for size in UiLayerHostOptions.allSizes { openWindow(size: size) }
    }

    @objc private func openSize(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSValue else { return }
        openWindow(size: value.sizeValue)
    }

    @objc private func toggleAnimation(_ sender: Any? = nil) {
        animator.toggle()
        animateItem?.state = animator.isRunning ? .on : .off
    }

    /// Steps every window through the sizes, its top-left corner fixed, so the layout reflows live.
    @objc private func toggleCycleSizes(_ sender: Any? = nil) {
        if let cycleTask {
            cycleTask.cancel()
            self.cycleTask = nil
        } else {
            cycleTask = Task { [weak self] in
                var step = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(2_400))
                    guard let self, !Task.isCancelled else { return }
                    step += 1
                    for (index, window) in self.windows.enumerated() where window.isVisible {
                        let sizes = UiLayerHostOptions.allSizes
                        let size = sizes[(step + index) % sizes.count]
                        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
                        window.setUiLayerFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height,
                                                      width: frame.width, height: frame.height))
                    }
                }
            }
        }
        cycleItem?.state = cycleTask == nil ? .off : .on
    }

    @objc private func reloadLook(_ sender: Any?) { look.reload() }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit cmux UI layer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "cmux UI layer")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("New Window", #selector(newWindow(_:)), "n"))
        windowMenu.addItem(item("Open All Sizes", #selector(openAllSizes(_:)), "N"))
        let sizes = NSMenu()
        for size in UiLayerHostOptions.allSizes {
            let entry = item("\(Int(size.width)) × \(Int(size.height))", #selector(openSize(_:)), "")
            entry.representedObject = NSValue(size: size)
            sizes.addItem(entry)
        }
        windowMenu.addItem(submenu: sizes, title: "New Window at Size")
        windowMenu.addItem(.separator())
        let animate = item("Animate", #selector(toggleAnimation(_:)), "A")
        animateItem = animate
        windowMenu.addItem(animate)
        let cycle = item("Cycle Sizes", #selector(toggleCycleSizes(_:)), "S")
        cycleItem = cycle
        windowMenu.addItem(cycle)
        windowMenu.addItem(item("Reload App Look", #selector(reloadLook(_:)), "r"))
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: windowMenu, title: "Window")
        NSApp.windowsMenu = windowMenu
        return main
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        submenu.title = title
        item.submenu = submenu
        addItem(item)
    }
}

/// The empty parts of a window drag it, as the app's chrome does (SwiftUI's hosting view does not
/// pass background drags to `isMovableByWindowBackground`).
struct UiLayerDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
