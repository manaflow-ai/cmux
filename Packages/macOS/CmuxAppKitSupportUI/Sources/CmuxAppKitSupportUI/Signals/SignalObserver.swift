@MainActor
enum SignalObserverKind {
    case memo
    case effect
}

@MainActor
protocol SignalObserver: AnyObject {
    var observerKind: SignalObserverKind { get }

    func observe(_ dependency: any SignalDependency)
    func run()
}
