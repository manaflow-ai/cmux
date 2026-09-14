import Foundation

/// An encoded command and the capacity held until its write or input receipt.
struct CloudTuiManualIOWrite: Sendable {
    let line: Data
    let reservation: CloudTuiManualIOReservation
}
