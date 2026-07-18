import CmuxFoundation
import CMUXAgentLaunch
import Foundation
import Observation
import SwiftUI

/// Mirrors the process-wide Feed projection into one panel's observable state.
@MainActor
@Observable
final class FeedPanelViewModel {
    private(set) var items: [WorkstreamItem] = []
    private(set) var presentation = FeedPresentationSnapshot.empty

    @ObservationIgnored private let presentationStore: FeedPresentationStore

    init(coordinator: FeedCoordinator = .shared) {
        self.presentationStore = coordinator.presentationStore
        arm()
    }

    private func arm() {
        withObservationTracking {
            items = presentationStore.items
            presentation = presentationStore.presentation
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.arm()
            }
        }
    }

}
