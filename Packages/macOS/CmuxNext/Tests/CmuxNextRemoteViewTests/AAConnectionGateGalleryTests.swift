import Foundation
@testable import CmuxNextRemoteView
import Testing

/// Connection-gate gallery fixtures. Keep the variants together so the desktop, terminal,
/// browser and port-preview gates all use the same copy and hierarchy when their native hosts
/// start feeding this shared view.
@Suite struct AAConnectionGateGalleryTests {
    static let variants: [RemoteConnectionTarget] = [
        RemoteConnectionTarget(name: "Nightly desktop", status: "Running", region: "us-west", kind: .desktop),
        RemoteConnectionTarget(name: "Paused build box", status: "Paused", region: "eu-central", kind: .desktop),
        RemoteConnectionTarget(name: "Studio terminal", status: "Running", region: "us-west", kind: .terminal),
        RemoteConnectionTarget(name: "Preview browser", status: "Running", region: "us-west", kind: .browser),
        RemoteConnectionTarget(name: "Port 3000", status: "Running", region: "us-west", kind: .ports),
    ]

    @Test func galleryHasDistinctHumanReadableVariants() {
        let cards = Self.variants.map { RemoteViewUnavailableView.text(for: .confirmTarget($0)) }
        #expect(cards.count >= 3)
        #expect(Set(cards.map(\.title)).count == cards.count)
        #expect(cards.allSatisfy { !$0.title.contains("vm_") && !$0.detail.contains("machine:") })
    }
}
