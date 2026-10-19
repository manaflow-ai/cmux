/// A failed output-reader system call and its captured POSIX error number.
enum SimulatorProcessOutputFailure: Error, Equatable, Sendable {
    case duplicateDescriptor(errorNumber: Int32)
    case cancellationPipe(errorNumber: Int32)
    case poll(errorNumber: Int32)
    case read(errorNumber: Int32)
}
