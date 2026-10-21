import Observation

/// Holds the vault list's resolved colors; the host view updates it on theme changes.
@MainActor
@Observable
final class VaultAppearance {
    var colors = VaultColors()
}
