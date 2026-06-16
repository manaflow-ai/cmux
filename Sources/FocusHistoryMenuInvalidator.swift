import AppKit
import SwiftUI

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
    }

    deinit {
        for observer in observers {
            center.removeObserver(observer)
        }
    }
}
