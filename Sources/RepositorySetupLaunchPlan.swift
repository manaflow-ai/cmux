import Bonsplit
import CmuxSettings

enum RepositorySetupLaunchPlan: Equatable {
    case backgroundTab
    case split(SplitOrientation)

    init(location: TerminalSetupScriptLocation) {
        switch location {
        case .backgroundTab:
            self = .backgroundTab
        case .verticalSplit:
            self = .split(.horizontal)
        case .horizontalSplit:
            self = .split(.vertical)
        }
    }
}
