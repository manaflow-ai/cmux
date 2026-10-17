#if os(macOS)
import AppKit

/// Keeps the bundled command-line client out of macOS application surfaces.
enum CLIApplicationPolicy {
    static func apply(
        setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
    ) {
        setActivationPolicy(.prohibited)
    }

    @MainActor
    static func apply() {
        apply(application: .shared)
    }

    @MainActor
    static func apply(application: NSApplication) {
        apply { policy in
            application.setActivationPolicy(policy)
        }
    }
}
#endif
