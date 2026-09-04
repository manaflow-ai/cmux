/// Internal control errors for the host event writer lifecycle.
///
/// `superseded` permits one replacement open, `closed` represents permanent
/// teardown, and `writeTimedOut` represents a write that exceeded its deadline.
enum MobileHostIrxEventWriterOpenError: Error {
    case superseded
    case closed
    case writeTimedOut
}
