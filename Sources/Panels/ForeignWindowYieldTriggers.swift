import AppKit

/// App-wide observers that hold a foreign-window yield while cmux floats UI
/// over pane content, so hosted other-process windows do not cover it.
///
/// Wired: the command palette, sheets attached to main windows (NSAlert
/// sheets and SwiftUI `.sheet`/`.alert`), and every NSPopover (SwiftUI
/// `.popover` included). Not wired: NSMenu (context and menu bar menus) and
/// app-modal `runModal` alerts, which AppKit orders at window levels above
/// other apps' normal windows, so they already render over foreign windows.
@MainActor
final class ForeignWindowYieldTriggers {
    static let shared = ForeignWindowYieldTriggers()

    private enum Kind: String {
        case commandPalette = "command-palette"
        case sheet
        case popover
    }

    private struct Key: Hashable {
        let kind: Kind
        let object: ObjectIdentifier
    }

    private var observers: [NSObjectProtocol] = []
    private var tokens: [Key: ForeignWindowYieldCoordinator.Token] = [:]

    /// Installs the observers once; safe to call repeatedly.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: .commandPaletteVisibilityDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                let visible = notification.userInfo?["visible"] as? Bool ?? false
                let key = Key(kind: .commandPalette, object: ObjectIdentifier(window))
                // Posted on the main thread by AppDelegate.setCommandPaletteVisible.
                MainActor.assumeIsolated {
                    self?.setYield(visible, for: key)
                }
            },
            center.addObserver(
                forName: NSWindow.willBeginSheetNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                // AppKit sheet notifications are delivered on the main run loop.
                MainActor.assumeIsolated {
                    guard AppDelegate.shared?.isMainTerminalWindow(window) == true else { return }
                    self?.setYield(true, for: Key(kind: .sheet, object: ObjectIdentifier(window)))
                }
            },
            center.addObserver(
                forName: NSWindow.didEndSheetNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                let key = Key(kind: .sheet, object: ObjectIdentifier(window))
                MainActor.assumeIsolated {
                    self?.setYield(false, for: key)
                }
            },
            center.addObserver(
                forName: NSPopover.willShowNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let popover = notification.object as? NSPopover else { return }
                let key = Key(kind: .popover, object: ObjectIdentifier(popover))
                // NSPopover notifications are delivered on the main run loop.
                MainActor.assumeIsolated {
                    self?.setYield(true, for: key)
                }
            },
            center.addObserver(
                forName: NSPopover.didCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let popover = notification.object as? NSPopover else { return }
                let key = Key(kind: .popover, object: ObjectIdentifier(popover))
                MainActor.assumeIsolated {
                    self?.setYield(false, for: key)
                }
            },
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                let object = ObjectIdentifier(window)
                // A window closing with its palette or sheet still up never
                // posts the hide/end notification; release its yields here.
                MainActor.assumeIsolated {
                    self?.setYield(false, for: Key(kind: .commandPalette, object: object))
                    self?.setYield(false, for: Key(kind: .sheet, object: object))
                }
            },
        ]
    }

    /// Idempotent: repeated shows keep one token, repeated hides are no-ops.
    private func setYield(_ active: Bool, for key: Key) {
        let coordinator = ForeignWindowYieldCoordinator.shared
        if active {
            guard tokens[key] == nil else { return }
            tokens[key] = coordinator.beginYield(reason: key.kind.rawValue)
        } else if let token = tokens.removeValue(forKey: key) {
            coordinator.endYield(token)
        }
    }
}
