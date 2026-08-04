import OSLog

struct DynamicTracingSignposts {
    private let signposter: OSSignposter

    init(subsystem: String) {
        self.signposter = OSSignposter(subsystem: subsystem, category: .dynamicTracing)
    }

    @inline(__always)
    func begin(_ name: StaticString, _ message: @autoclosure () -> String) -> DynamicTracingSignpostInterval? {
        guard signposter.isEnabled else { return nil }
        let details = message()
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID(), "\(details, privacy: .public)")
        return DynamicTracingSignpostInterval(name: name, state: state)
    }

    @inline(__always)
    func end(_ interval: DynamicTracingSignpostInterval?) {
        guard let interval else { return }
        signposter.endInterval(interval.name, interval.state)
    }
}
