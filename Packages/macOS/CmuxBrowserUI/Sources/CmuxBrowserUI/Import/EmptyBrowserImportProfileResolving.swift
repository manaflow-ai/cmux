import Foundation
import CmuxBrowser

/// A no-destination profile resolver used by ``BrowserDataImportCoordinator``
/// only when the app has not called
/// ``BrowserDataImportCoordinator/configure(profileResolver:importPersistence:)``.
///
/// In practice this is reached solely by DEBUG wizard-construction probes that
/// pass their destination profiles explicitly, so the fallback values are never
/// observed. It never creates profiles.
@MainActor
struct EmptyBrowserImportProfileResolving: BrowserImportProfileResolving {
    var profiles: [BrowserProfileDefinition] { [] }

    var effectiveLastUsedProfileID: UUID { UUID() }

    func profileDefinition(id: UUID) -> BrowserProfileDefinition? { nil }

    func createProfile(named rawName: String) -> BrowserProfileDefinition? { nil }

    func displayName(for id: UUID) -> String { "" }
}
