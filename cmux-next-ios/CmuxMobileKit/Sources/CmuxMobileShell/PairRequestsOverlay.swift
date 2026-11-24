#if os(iOS) && canImport(CmuxMobileLinkFFI)
import CmuxMobileDesign
import CmuxMobileLive
import SwiftUI

/// The "Allow on this phone" cards over the app (ask-45c37458ea): one per device waiting for a
/// linked Mac's Allow (``MacPairRequests``), newest Mac's last.
struct PairRequestsOverlay: View {
    let requests: MacPairRequests

    var body: some View {
        // Up to eight cards per Mac, with large text: they scroll within the screen instead of
        // pushing the lower cards' buttons off it. Empty: no scroll view takes the top's touches.
        if !requests.cards.isEmpty {
            ScrollView(.vertical) { cardStack }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cardStack: some View {
        VStack(spacing: 10) {
            ForEach(requests.cards) { card in
                PairRequestCardView(
                    deviceName: card.request.name,
                    macName: card.macName,
                    fingerprint: card.request.fingerprintShown,
                    answering: card.answering,
                    failed: card.failed,
                    onAllow: { requests.answer(card, allow: true) },
                    onDeny: { requests.answer(card, allow: false) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .animation(.snappy, value: requests.cards.map(\.id))
    }
}
#endif
