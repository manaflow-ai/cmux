import Foundation
import Observation

/// Retains a window's reveal request while the Cloud sidebar is hidden or loading.
@MainActor
@Observable
final class CloudSidebarNavigationState {
    struct Request: Equatable {
        let id = UUID()
        let target: CloudSidebarRevealTarget
    }

    private var request: Request?
    @ObservationIgnored private var completedRequestID: UUID?

    var pendingRequest: Request? {
        guard let request, request.id != completedRequestID else { return nil }
        return request
    }

    /// Completion changes no rendered value; it only prevents replay after remount.
    func complete(_ id: UUID) {
        completedRequestID = id
    }

    func reveal(_ target: CloudSidebarRevealTarget) {
        request = Request(target: target)
    }
}
