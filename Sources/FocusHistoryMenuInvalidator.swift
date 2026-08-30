import AppKit
import SwiftUI

extension Notification.Name {
    static let dockMenuCapabilitiesDidChange = Notification.Name(
        "cmux.dockMenuCapabilitiesDidChange"
    )
    static let browserFindCapabilityDidChange = Notification.Name(
        "cmux.browserFindCapabilityDidChange"
    )
    static let terminalSelectionDidChange = Notification.Name(
        "cmux.terminalSelectionDidChange"
    )
}

@MainActor
final class FocusHistoryMenuInvalidator: ObservableObject {
    @Published private(set) var revision: UInt64 = 0

    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        self.center = center
        observers.append(center.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.revision &+= 1
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.revision &+= 1
            }
        })
        observers.append(center.addObserver(
            forName: .dockMenuCapabilitiesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      self.shouldInvalidateForDockNotification(notification) else {
                    return
                }
                self.revision &+= 1
            }
        })
    }

    /// Dock capability updates from an inactive store cannot affect the
    /// currently rendered app menu. Key-window transitions and focus-owner
    /// notifications still invalidate the snapshot when that store becomes
    /// active, so filtering here avoids rebuilding every command for hidden
    /// or background Docks.
    private func shouldInvalidateForDockNotification(_ notification: Notification) -> Bool {
        guard let dock = notification.object as? DockSplitStore else {
            // Focus-controller notifications carry the owner rather than the
            // Dock itself and must always invalidate the active-store lookup.
            return true
        }
        return AppDelegate.shared?.focusedDockStoreForShortcut(
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
        ) === dock
    }

    deinit {
        for observer in observers {
            center.removeObserver(observer)
        }
    }
}
