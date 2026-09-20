import AppKit

/// Owns click-away dismissal for a menu and its nested popovers.
///
/// Pass the same instance to each ``ArrowlessPopoverAnchor`` in the menu.
/// Members use application-defined behavior because AppKit does not support
/// anchoring a semitransient popover inside another popover.
@MainActor
public final class CmuxPopoverGroup {
    private struct Member {
        let id: UUID
        let parent: UUID?
        let contains: (Int?, CGPoint) -> Bool
        let containsPointer: (Int?, CGPoint) -> Bool
        let close: () -> Void
    }

    private var members: [Member] = []
    private var windows: [UUID: () -> NSWindow?] = [:]
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var activationObserver: (any NSObjectProtocol)?

    /// Creates an independent dismissal group for one menu presentation.
    public init() {}

    func register(popover: NSPopover, anchor: NSView) -> UUID {
        let id = UUID()
        let parent = members.last { windows[$0.id]?() === anchor.window }?.id
        let contains: (Int?, CGPoint) -> Bool = { [weak popover, weak anchor] windowNumber, point in
            if let window = popover?.contentViewController?.view.window,
               popover?.isShown == true,
               windowNumber == nil || windowNumber == window.windowNumber,
               window.frame.contains(point) {
                return true
            }
            // Let the footer button toggle its own menu on a second click.
            guard parent == nil, let anchor, let window = anchor.window,
                  windowNumber == nil || windowNumber == window.windowNumber else { return false }
            return window.convertToScreen(anchor.convert(anchor.bounds, to: nil)).contains(point)
        }
        let containsPointer: (Int?, CGPoint) -> Bool = { [weak popover, weak anchor] windowNumber, point in
            if let window = popover?.contentViewController?.view.window,
               popover?.isShown == true,
               windowNumber == nil || windowNumber == window.windowNumber,
               window.frame.insetBy(dx: -14, dy: -14).contains(point) {
                return true
            }
            guard parent == nil, let anchor, let window = anchor.window,
                  windowNumber == nil || windowNumber == window.windowNumber else { return false }
            return window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                .insetBy(dx: -14, dy: -14)
                .contains(point)
        }
        register(
            id: id,
            parent: parent,
            contains: contains,
            containsPointer: containsPointer,
            close: { [weak popover] in popover?.close() }
        )
        windows[id] = { [weak popover] in popover?.contentViewController?.view.window }
        startMonitoring()
        return id
    }

    // The lifecycle and hit-testing seam is independent of AppKit windows so
    // tests can drive the same click/close path with synthetic menu rectangles.
    func register(
        id: UUID,
        parent: UUID?,
        contains: @escaping (Int?, CGPoint) -> Bool,
        containsPointer: ((Int?, CGPoint) -> Bool)? = nil,
        close: @escaping () -> Void
    ) {
        members.append(Member(
            id: id,
            parent: parent,
            contains: contains,
            containsPointer: containsPointer ?? contains,
            close: close
        ))
    }

    func handleClick(windowNumber: Int?, point: CGPoint) {
        guard !members.contains(where: { $0.contains(windowNumber, point) }) else { return }
        dismissAll()
    }

    func handleMove(windowNumber: Int?, point: CGPoint) {
        let childMembers = members.filter { $0.parent != nil }
        guard !childMembers.isEmpty,
              !childMembers.contains(where: { $0.containsPointer(windowNumber, point) }) else { return }
        // Hover only controls the nested submenu. The account popover remains
        // application-defined and closes on an explicit outside click.
        for member in childMembers.reversed() {
            unregister(member.id)
        }
    }

    /// Closes children before their parent so no detached child can retain an
    /// empty parent popover window. Safe when a close callback re-enters here.
    func unregister(_ id: UUID) {
        var removed: Set<UUID> = [id]
        for member in members where member.parent.map(removed.contains) == true {
            removed.insert(member.id)
        }
        let children = members.filter { $0.id != id && removed.contains($0.id) }
        members.removeAll { removed.contains($0.id) }
        for removedID in removed { windows[removedID] = nil }
        if members.isEmpty { stopMonitoring() }
        for member in children.reversed() { member.close() }
    }

    /// Dismisses the entire menu, preserving the underlying click event.
    public func dismissAll() {
        let closing = members.reversed()
        members = []
        windows = [:]
        stopMonitoring()
        for member in closing { member.close() }
    }

    private func startMonitoring() {
        guard localMonitor == nil else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union([.keyDown, .mouseMoved])) { [weak self] event in
            // AppKit delivers local event monitors on the main thread.
            let consumed = MainActor.assumeIsolated {
                if event.type == .keyDown {
                    guard event.keyCode == 53 else { return false }
                    self?.dismissAll()
                    return true
                }
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                if event.type == .mouseMoved {
                    self?.handleMove(windowNumber: event.window?.windowNumber, point: point)
                } else {
                    self?.handleClick(windowNumber: event.window?.windowNumber, point: point)
                }
                return false
            }
            return consumed ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks.union(.mouseMoved)) { [weak self] event in
            guard event.type != .mouseMoved else { return }
            MainActor.assumeIsolated { self?.dismissAll() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissAll() }
        }
    }

    private func stopMonitoring() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        localMonitor = nil
        globalMonitor = nil
        activationObserver = nil
    }
}
