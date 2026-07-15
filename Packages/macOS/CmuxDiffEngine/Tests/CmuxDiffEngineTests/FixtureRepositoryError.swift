enum FixtureRepositoryError: Error {
    case gitFailed(arguments: [String], diagnostic: String)
}
