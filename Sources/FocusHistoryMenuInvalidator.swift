import AppKit
import CmuxFoundation
import SwiftUI

@MainActor
final class FocusHistoryMenuInvalidator: ObservableObject {
    typealias DeadlineCancellation = @MainActor () -> Void
    typealias DeadlineScheduler = @MainActor (
        TimeInterval,
        @escaping @MainActor () -> Void
    ) -> DeadlineCancellation

    @Published private(set) var revision: UInt64 = 0

    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private let batcher: LatestWinsBatcher<Bool, Bool>

    convenience init(center: NotificationCenter = .default) {
        self.init(
            center: center,
            batcher: LatestWinsBatcher(
                quietDelay: 0.04,
                maximumDelay: 0.12
            )
        )
    }

    /// Internal scheduler seam used by behavior tests to drive the real
    /// notification path without wall-clock sleeps.
    convenience init(
        center: NotificationCenter,
        scheduler: @escaping DeadlineScheduler
    ) {
        self.init(
            center: center,
            batcher: LatestWinsBatcher(
                quietDelay: 0.04,
                maximumDelay: 0.12,
                scheduler: scheduler
            )
        )
    }

    private init(
        center: NotificationCenter,
        batcher: LatestWinsBatcher<Bool, Bool>
    ) {
        self.center = center
        self.batcher = batcher
        observers.append(center.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidate()
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
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
