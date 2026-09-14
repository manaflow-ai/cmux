/// The first rejection owns shutdown; subsequent calls retain no new work.
enum CloudTuiManualIOAdmissionResult: Equatable, Sendable {
    case reserved
    case rejected
    case closed
}
