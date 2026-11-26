import Foundation

/// An error declared outside this package that knows its ``CloudDiagnosticFailure`` class.
///
/// ``CloudDiagnosticFailure/classify(_:)`` asks a conforming error for its class
/// instead of naming the error type, so errors owned by the app (for example the
/// Cloud surface provider's) keep their classification without this package
/// depending on the app.
public protocol CloudDiagnosticFailureClassifying: Error {
    /// The diagnostic class recorded for this error.
    var cloudDiagnosticFailure: CloudDiagnosticFailure { get }
}
