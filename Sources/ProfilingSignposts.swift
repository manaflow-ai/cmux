import Foundation
import OSLog

struct DynamicTracingSignposts {
    struct Interval {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
    }

    private let signposter: OSSignposter

    init(subsystem: String) {
        self.signposter = OSSignposter(subsystem: subsystem, category: .dynamicTracing)
    }

    @inline(__always)
    func begin(_ name: StaticString, _ message: @autoclosure () -> String) -> Interval? {
        guard signposter.isEnabled else { return nil }
        let details = message()
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID(), "\(details, privacy: .public)")
        return Interval(name: name, state: state)
    }

    @inline(__always)
    func end(_ interval: Interval?) {
        guard let interval else { return }
        signposter.endInterval(interval.name, interval.state)
    }
}

enum SidebarProfilingSignposts {
    private static let signposts = DynamicTracingSignposts(subsystem: "com.cmux.sidebar")

    @inline(__always)
    static func begin(_ name: StaticString, _ message: @autoclosure () -> String) -> DynamicTracingSignposts.Interval? {
        signposts.begin(name, message())
    }

    @inline(__always)
    static func end(_ interval: DynamicTracingSignposts.Interval?) {
        signposts.end(interval)
    }
}

enum MobileWorkspaceObserverSignposts {
    private static let signposts = DynamicTracingSignposts(subsystem: "dev.cmux.mobile-workspace-observer")

    @inline(__always)
    static func begin(_ name: StaticString, _ message: @autoclosure () -> String) -> DynamicTracingSignposts.Interval? {
        signposts.begin(name, message())
    }

    @inline(__always)
    static func end(_ interval: DynamicTracingSignposts.Interval?) {
        signposts.end(interval)
    }
}

func debugShortSidebarTabId(_ id: UUID?) -> String {
    guard let id else { return "nil" }
    return String(id.uuidString.prefix(5))
}
