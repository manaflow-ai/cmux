#if os(macOS)
import AppKit

/// Keeps the bundled command-line client out of macOS application surfaces.
@MainActor
struct CLIApplicationPolicy {
    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Bool

    init(setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Bool) {
        self.setActivationPolicy = setActivationPolicy
    }

    init(application: NSApplication) {
        self.init { policy in
            application.setActivationPolicy(policy)
        }
    }

    func apply() -> Bool {
        setActivationPolicy(.prohibited)
    }
}
#endif
