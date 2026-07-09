import AppKit
internal import CmuxFoundation
import SwiftUI

@MainActor
final class FocusHistoryMenuInvalidator: ObservableObject {
    @Published private(set) var revision: UInt64 = 0

    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private let batcher = LatestWinsBatcher<Bool, Bool>(
        quietDelay: 0.04,
        maximumDelay: 0.12
    )

    init(center: NotificationCenter = .default) {
        self.center = center
        observers.append(center.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.invalidate()
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.invalidate()
            }
        })
    }

    deinit {
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    private func invalidate() {
        batcher.submit(true, for: true) { [weak self] _ in
            self?.revision &+= 1
        }
    }
}
