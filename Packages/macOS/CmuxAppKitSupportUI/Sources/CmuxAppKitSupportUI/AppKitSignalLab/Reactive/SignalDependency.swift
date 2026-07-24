@MainActor
protocol SignalDependency: AnyObject {
    func addObserver(_ observer: any SignalObserver)
    func removeObserver(_ observer: any SignalObserver)
}
