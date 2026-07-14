extension SharedLiveAgentIndex {
    enum RefreshOutcome {
        case result(LoadResult)
        case unavailable

        var loadResult: LoadResult? {
            switch self {
            case .result(let result): result
            case .unavailable: nil
            }
        }
    }
}
