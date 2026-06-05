struct CLISocketReadEOFError: Error, CustomStringConvertible, CLISocketExpectedAvailabilityError {
    let message: String

    var description: String { message }
}
