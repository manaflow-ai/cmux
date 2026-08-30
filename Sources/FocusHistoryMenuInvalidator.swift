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
        ) { [weak self] _ in
            Task { @MainActor in
                self?.revision &+= 1
            }
        })
    }

    deinit {
        for observer in observers {
            center.removeObserver(observer)
        }
    }
}
