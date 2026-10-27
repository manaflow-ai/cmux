import Observation

/// When the diagram engine loaded for Mermaid fences that mapped as text while it was cold
/// (``HomeDiagramRowProvider/warm()``). Observable: a projection reads ``loads`` inside an
/// observation and maps its rows again when it changes.
@Observable @MainActor
final class HomeDiagramReadiness {
    /// How many times the engine loaded with fences waiting for it.
    private(set) var loads = 0

    nonisolated init() {}

    /// The engine loaded and some fence mapped as text meanwhile.
    func engineLoaded() {
        loads += 1
    }
}
