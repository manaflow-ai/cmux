#if os(macOS)
import AppKit

/// Keeps the bundled command-line client out of macOS application surfaces.
enum CLIApplicationPolicy {
    static func apply(
        setActivationPolicy: (NSApplication.ActivationPolicy) -> Bool
    ) -> Bool {
        setActivationPolicy(.prohibited)
    }

    @MainActor
    static func apply() -> Bool {
        apply(application: .shared)
    }

    @MainActor
    static func apply(application: NSApplication) -> Bool {
        apply { policy in
            application.setActivationPolicy(policy)
        }
    }
}
#endif
