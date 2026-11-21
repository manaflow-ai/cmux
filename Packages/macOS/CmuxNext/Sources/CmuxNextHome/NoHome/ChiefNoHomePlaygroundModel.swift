#if DEBUG
import Observation

/// DEBUG ONLY: what the no-Home prototype shows: the variant picked in its bar.
@MainActor @Observable
final class ChiefNoHomePlaygroundModel {
    var variant: ChiefNoHomeVariant = .threads
    let fixture = ChiefNoHomeFixture()
}
#endif
