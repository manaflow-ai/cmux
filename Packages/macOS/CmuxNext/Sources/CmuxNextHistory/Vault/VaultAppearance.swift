package import Observation

/// Holds the vault list's resolved colors; the host view updates it on theme changes.
@MainActor
@Observable
package final class VaultAppearance {
    package init() {}

    package var colors = VaultColors()
}
