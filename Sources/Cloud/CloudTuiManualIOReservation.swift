/// Retains one admission charge through every queue that owns its payload.
final class CloudTuiManualIOReservation: Sendable {
    private let admission: CloudTuiManualIOAdmission
    private let bytes: Int
    private let framedBytes: Int

    init(admission: CloudTuiManualIOAdmission, bytes: Int, framedBytes: Int = 0) {
        self.admission = admission
        self.bytes = bytes
        self.framedBytes = framedBytes
    }

    deinit { admission.release(bytes, framedBytes: framedBytes) }
}
