import Observation

/// Observable administrative admission used with the actual machine registry.
@Observable @MainActor
final class CatalogTestPolicy {
    var blocked = false
}
