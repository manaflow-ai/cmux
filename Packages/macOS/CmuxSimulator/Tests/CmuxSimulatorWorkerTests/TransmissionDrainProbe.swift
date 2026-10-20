@MainActor
final class TransmissionDrainProbe {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
