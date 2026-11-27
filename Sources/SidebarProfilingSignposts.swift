enum SidebarProfilingSignposts {
    private static let signposts = DynamicTracingSignposts(subsystem: "com.cmux.sidebar")

    @inline(__always)
    static func begin(_ name: StaticString, _ message: @autoclosure () -> String) -> DynamicTracingSignpostInterval? {
        signposts.begin(name, message())
    }

    @inline(__always)
    static func end(_ interval: DynamicTracingSignpostInterval?) {
        signposts.end(interval)
    }
}
