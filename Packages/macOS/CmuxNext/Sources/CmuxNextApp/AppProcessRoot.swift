/// The process root (plans/cmux-next/crash-elimination.md, P1b): the app's one
/// `AppServices`, held here for the life of the process. Many service objects
/// keep an `unowned` back-reference to `AppServices`; they are safe because their
/// owner is never freed while the process runs, and this holder is what makes
/// that true by choice (crash-allowlist.json entries: "owner is the explicit
/// process root AppServices"). The launch adopts the services right after making
/// them. Tests that build their own services do not adopt them.
@MainActor
final class AppProcessRoot {
    static let shared = AppProcessRoot()

    /// The adopted services; never released once set.
    private(set) var services: AppServices?

    /// Holds `services` for the rest of the process.
    func adopt(_ services: AppServices) {
        self.services = services
    }
}
