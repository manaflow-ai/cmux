import Foundation
import Observation

/// Owns cmux's process-scoped idle-sleep activity.
///
/// The assertion keeps the Mac reachable while its display remains free to
/// sleep. It is intentionally not persisted: quitting cmux always releases it.
@MainActor
@Observable
final class CaffeineController {
    typealias BeginActivity = () -> any NSObjectProtocol
    typealias EndActivity = (any NSObjectProtocol) -> Void

    private(set) var isEnabled = false

    @ObservationIgnored private let beginActivity: BeginActivity
    @ObservationIgnored private let endActivity: EndActivity
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored var onStateChange: ((Bool) -> Void)?

    init(
        beginActivity: @escaping BeginActivity = {
            ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "cmux Keep Mac Awake"
            )
        },
        endActivity: @escaping EndActivity = { activity in
            ProcessInfo.processInfo.endActivity(activity)
        }
    ) {
        self.beginActivity = beginActivity
        self.endActivity = endActivity
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }

        if enabled {
            activity = beginActivity()
        } else if let activity {
            endActivity(activity)
            self.activity = nil
        }

        isEnabled = enabled
        onStateChange?(enabled)
    }

    func toggle() {
        setEnabled(!isEnabled)
    }
}
