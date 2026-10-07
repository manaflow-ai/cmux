import Foundation

/// Runs blocking file work (whole-file hashing, copies) on a dispatch queue
/// so it never occupies a Swift concurrency cooperative thread.
struct BlockingIO {
    private static let queue = DispatchQueue(label: "cmux.mobile.files.io", qos: .utility, attributes: .concurrent)

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
