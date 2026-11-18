// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG && os(iOS)
import CmuxMobileDesign
import SwiftUI

/// Every sample card (`UISurfaceFixtures.all`) in one column, with presses answered locally: the
/// SwiftUI preview of the cards, and of each one's confirm strip after a press.
struct UISurfaceGallery: View {
    @State private var host = UISurfaceHost(actions: UISurfaceGalleryActions())

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(UISurfaceFixtures.all.enumerated()), id: \.offset) { _, sample in
                    if let surface = UISurface(json: sample.surface) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sample.name).font(CmuxMobileTheme.standard.type.legal).foregroundStyle(.tertiary)
                            UISurfaceCard(surface: surface, host: host)
                        }
                    } else {
                        UISurfaceFallbackView(text: "\(sample.name) did not decode")
                    }
                }
            }
            .padding(20)
        }
        .background(Color.cmuxMobileBackground)
    }
}

/// Presses in the gallery: a Pending naming what would be sent, and nothing sent.
@MainActor
final class UISurfaceGalleryActions: UISurfaceActions {
    func action(surfaceId: String, actionId: String, values: [String: JSONValue]) async -> UISurface.Pending? {
        let sends = values.sorted { $0.key < $1.key }.map { UISurface.Pending.Send(label: $0.key, value: $0.value.uiSurfaceText) }
        let list = sends.map { "\($0.label) = \($0.value)" }.joined(separator: ", ")
        return UISurface.Pending(requestId: UUID().uuidString, actionId: actionId,
                                 summary: list.isEmpty ? "Send \"\(actionId)\" to the agent" : "Send \"\(actionId)\" to the agent with: \(list)",
                                 sends: sends, target: "agent")
    }

    func confirm(surfaceId: String, requestId: String) {}
    func cancel(surfaceId: String, requestId: String) {}
}

#Preview("Agent UI surfaces") {
    UISurfaceGallery()
}

#Preview("Agent UI surfaces, accessibility text") {
    UISurfaceGallery().environment(\.dynamicTypeSize, .accessibility2)
}
#endif
