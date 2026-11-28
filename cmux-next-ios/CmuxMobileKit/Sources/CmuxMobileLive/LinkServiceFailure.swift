/// The HTTP failure shape the link controller needs, independent of the live API client.
protocol LinkServiceFailure: Error {
    var status: Int { get }
}
