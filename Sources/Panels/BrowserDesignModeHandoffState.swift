enum BrowserDesignModeHandoffState: Equatable {
    case idle
    case preparing
    case sent
    case failed(String)
}
