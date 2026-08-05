import Foundation

struct WordPathHoverCacheEntry {
    let request: WordPathHoverResolutionRequest
    let resolution: WordPathResolution?
    let storedAt: TimeInterval

    init(
        request: WordPathHoverResolutionRequest,
        resolution: WordPathResolution?,
        storedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        self.request = request
        self.resolution = resolution
        self.storedAt = storedAt
    }

    func updatingRequest(_ request: WordPathHoverResolutionRequest) -> Self {
        Self(request: request, resolution: resolution, storedAt: storedAt)
    }

    func hasFreshNegativeResult(
        at now: TimeInterval,
        maximumAge: TimeInterval
    ) -> Bool {
        guard resolution == nil else { return false }
        let age = now - storedAt
        return age >= 0 && age < maximumAge
    }
}
