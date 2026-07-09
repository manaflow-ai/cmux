public import Foundation

/// A typed reason a `cmux ssh` deep-link launch could not complete, carrying
/// only the data the app needs to build a localized failure dialog.
///
/// Extracted from the three failure call sites in AppDelegate's
/// `CmuxSSHURLProcessLauncher`. The user-facing `String(localized:)` copy stays
/// app-side (it must resolve in the app bundle, not the package bundle, so the
/// Japanese translation is preserved), so this type intentionally carries no
/// strings beyond the captured child `output`.
public enum CmuxSSHURLLaunchFailure: Sendable, Equatable {
    /// The bundled `cmux` CLI was missing or not executable in this app build.
    case missingCLI
    /// The child `cmux ssh` process exited with a nonzero status. The captured
    /// output is the (already byte-limited at presentation) child stdout/stderr.
    case nonzeroExit(status: Int32, output: String)
    /// `Process.run()` itself threw before the child started. `description` is
    /// the thrown error's `localizedDescription`.
    case launchThrew(description: String)
}
