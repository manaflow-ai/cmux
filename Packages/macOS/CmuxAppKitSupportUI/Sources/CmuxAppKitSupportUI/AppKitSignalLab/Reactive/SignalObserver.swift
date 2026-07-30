@MainActor
protocol SignalObserver: AnyObject {
    var schedulingPriority: Int { get }

    func observe(_ dependency: any SignalDependency)
    func run()
}
