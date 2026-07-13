@MainActor
final class StoredMacReconnectProgress {
    private var target: String?
    private var forgottenTargets: Set<String> = []

    var targetMacDeviceID: String? {
        get { target }
        set { target = newValue }
    }

    func markForgotten(_ macDeviceIDs: Set<String>) {
        forgottenTargets.formUnion(macDeviceIDs)
    }

    func wasForgotten(_ macDeviceID: String) -> Bool {
        forgottenTargets.contains(macDeviceID)
    }
}
