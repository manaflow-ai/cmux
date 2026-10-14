#if os(macOS)
import AppKit

/// Keeps the bundled command-line client out of macOS application surfaces.
enum CLIApplicationPolicy {
    static func apply(
        setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
    ) {
        setActivationPolicy(.regular)
    }

    static func apply(application: NSApplication = .shared) {
        apply { policy in
            application.setActivationPolicy(policy)
        }
    }
}
#endif
