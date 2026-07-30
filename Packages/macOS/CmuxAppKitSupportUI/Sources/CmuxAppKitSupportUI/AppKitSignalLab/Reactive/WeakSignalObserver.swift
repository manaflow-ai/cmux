@MainActor
final class WeakSignalObserver {
    weak var value: (any SignalObserver)?

    init(_ value: any SignalObserver) {
        self.value = value
    }
}
