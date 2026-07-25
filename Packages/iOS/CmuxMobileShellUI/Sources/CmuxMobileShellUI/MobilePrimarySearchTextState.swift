#if os(iOS)
import Observation

@MainActor
@Observable
final class MobilePrimarySearchTextState {
    var workspaces = ""
    var notifications = ""
}
#endif
