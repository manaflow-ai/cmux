import CmuxNextApps
import Observation

/// Observable route source used by the real publisher lifecycle tests.
@Observable @MainActor
final class CatalogTestRegistry {
    var value: MachineCatalogSource?
    init(_ value: MachineCatalogSource?) { self.value = value }
}
