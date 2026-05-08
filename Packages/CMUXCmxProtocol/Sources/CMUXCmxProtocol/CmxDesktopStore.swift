import Foundation
import Observation

@MainActor
@Observable
public final class CmxDesktopStore {
    public private(set) var snapshot: CmxNativeSnapshot?
    public private(set) var lastErrorMessage: String?
    public private(set) var isClosed = false

    public init() {}

    public func apply(_ message: CmxServerMessage) {
        switch message {
        case .nativeSnapshot(let snapshot):
            self.snapshot = snapshot
            lastErrorMessage = nil
            isClosed = false
        case .error(let message):
            lastErrorMessage = message
        case .bye:
            isClosed = true
        default:
            break
        }
    }

    public func reset() {
        snapshot = nil
        lastErrorMessage = nil
        isClosed = false
    }
}
