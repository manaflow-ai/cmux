/// Internal control error used when a concurrent writer open is superseded.
enum MobileHostIrxEventWriterOpenError: Error {
    case superseded
    case closed
    case writeTimedOut
}
