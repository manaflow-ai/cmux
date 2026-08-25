@MainActor
struct WorkspaceSwitchSignposts {
    private let signposts: DynamicTracingSignposts

    init(
        signposts: DynamicTracingSignposts = DynamicTracingSignposts(
            subsystem: "com.cmux.workspace-switch"
        )
    ) {
        self.signposts = signposts
    }

    @inline(__always)
    func begin(
        _ name: StaticString,
        _ message: @autoclosure () -> String
    ) -> DynamicTracingSignpostInterval? {
        signposts.begin(name, message())
    }

    @inline(__always)
    func end(_ interval: DynamicTracingSignpostInterval?) {
        signposts.end(interval)
    }
}
