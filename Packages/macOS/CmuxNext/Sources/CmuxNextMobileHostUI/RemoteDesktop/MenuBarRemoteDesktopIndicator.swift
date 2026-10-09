public import AppKit
public import CmuxMobileHost
import CmuxRemoteDesktop

/// The host indicator (c3-rd.md 8): one menu bar item while any phone views
/// or controls this Mac, listing each session ("iPhone is viewing Display
/// 1") with Stop, plus Stop All. It cannot be dismissed while a session
/// lives; the item goes when the last session ends.
public struct MenuBarRemoteDesktopIndicator: RemoteDesktopIndicator {
    private let menu: RemoteDesktopStatusMenu
    private let deviceName: @Sendable (String) async -> String?

    /// - Parameter menu: the app's one status menu (made on the main actor).
    public init(menu: RemoteDesktopStatusMenu, deviceName: @escaping @Sendable (String) async -> String?) {
        self.menu = menu
        self.deviceName = deviceName
    }

    public func begin(_ session: RemoteDesktopIndicatorSession) async -> any RemoteDesktopIndicatorHandle {
        let device = await deviceName(session.install) ?? MobileHostStrings.unknownDevice
        let (stops, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let menu = menu
        await MainActor.run {
            menu.add(id, device: device, target: session.target.name, control: session.mode == .control, stop: continuation)
        }
        return StatusMenuHandle(id: id, menu: menu, stopRequests: stops)
    }
}

/// One session's entry.
struct StatusMenuHandle: RemoteDesktopIndicatorHandle {
    let id: UUID
    let menu: RemoteDesktopStatusMenu
    let stopRequests: AsyncStream<Void>

    func update(mode: DesktopMode) async {
        let menu = menu, id = id
        await MainActor.run { menu.setMode(id, control: mode == .control) }
    }

    func end() async {
        let menu = menu, id = id
        await MainActor.run { menu.remove(id) }
    }
}

/// The status item and its menu, rebuilt on every change. One per app.
@MainActor
public final class RemoteDesktopStatusMenu: NSObject {
    private struct Entry {
        var device: String
        var target: String
        var control: Bool
        let stop: AsyncStream<Void>.Continuation
    }

    private var entries: [(id: UUID, entry: Entry)] = []
    private var item: NSStatusItem?

    override public init() {
        super.init()
    }

    func add(_ id: UUID, device: String, target: String, control: Bool, stop: AsyncStream<Void>.Continuation) {
        entries.append((id, Entry(device: device, target: target, control: control, stop: stop)))
        rebuild()
    }

    func setMode(_ id: UUID, control: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].entry.control = control
        rebuild()
    }

    func remove(_ id: UUID) {
        entries.removeAll { entry in
            guard entry.id == id else { return false }
            entry.entry.stop.finish()
            return true
        }
        rebuild()
    }

    @objc private func stopOne(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let entry = entries.first(where: { $0.id == id }) else { return }
        entry.entry.stop.yield()
    }

    @objc private func stopAll(_ sender: NSMenuItem) {
        for entry in entries { entry.entry.stop.yield() }
    }

    private func rebuild() {
        guard !entries.isEmpty else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let item = self.item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        let control = entries.contains { $0.entry.control }
        item.button?.image = NSImage(systemSymbolName: control ? "cursorarrow.rays" : "rectangle.on.rectangle",
                                     accessibilityDescription: MobileHostStrings.indicatorLabel)
        item.button?.toolTip = MobileHostStrings.indicatorLabel
        let menu = NSMenu()
        for (id, entry) in entries {
            let title = MobileHostStrings.indicatorEntry(device: entry.device, target: entry.target, control: entry.control)
            menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            let stop = NSMenuItem(title: MobileHostStrings.stop, action: #selector(stopOne(_:)), keyEquivalent: "")
            stop.target = self
            stop.representedObject = id
            stop.indentationLevel = 1
            menu.addItem(stop)
        }
        menu.addItem(.separator())
        let all = NSMenuItem(title: MobileHostStrings.stopAll, action: #selector(stopAll(_:)), keyEquivalent: "")
        all.target = self
        menu.addItem(all)
        item.menu = menu
    }
}
