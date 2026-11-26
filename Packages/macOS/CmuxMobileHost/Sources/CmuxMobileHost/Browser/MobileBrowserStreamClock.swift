public import Foundation

public protocol MobileBrowserStreamClock: Sendable {
    var now: TimeInterval { get }
    func sleep(for interval: TimeInterval) async throws
}
