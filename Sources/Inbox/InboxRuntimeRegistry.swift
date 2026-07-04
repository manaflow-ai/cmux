import Foundation

@MainActor
enum InboxRuntimeRegistry {
    private(set) static weak var current: InboxRuntime?

    static func install(_ runtime: InboxRuntime) {
        current = runtime
    }
}
