import Foundation

extension SharedLiveAgentIndex {
    enum RefreshPublication: Equatable {
        case scoped
        case workspace

        mutating func include(_ other: Self) {
            if other == .workspace {
                self = .workspace
            }
        }
    }
}
