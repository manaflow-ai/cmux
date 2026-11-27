#if os(iOS)
@testable import CmuxTabsKit
import SwiftUI
import Testing
import UIKit

/// A grid card's content is told the page size the kit lays it out at (`tabsKitCardPageSize`);
/// the card's long-press preview, which lays the card out at its own size, tells it nothing, so a
/// host never takes a card's size for the page's.
@MainActor @Suite(.serialized) struct CardPageSizeTests {
    @MainActor final class Seen {
        var sizes: [CGSize?] = []
    }

    struct Probe: View {
        let seen: Seen
        @Environment(\.tabsKitCardPageSize) private var pageSize
        var body: some View {
            Color.clear.onChange(of: pageSize, initial: true) { _, size in seen.sizes.append(size) }
        }
    }

    func host(_ view: some View, size: CGSize) async -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        for _ in 0 ..< 5 {
            window.rootViewController?.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(16))
        }
        return window
    }

    @Test func aGridCardIsToldThePageSize() async {
        let seen = Seen()
        let page = CGSize(width: 874, height: 402)
        let window = await host(TabCard(title: "t", systemImage: "doc", pageSize: page, width: 177, height: 249, radius: 12,
                                        showsClose: true, closeOpacity: 1, titleOpacity: 1, onClose: {}) { Probe(seen: seen) },
                                size: CGSize(width: 402, height: 874))
        defer { window.isHidden = true }
        #expect(seen.sizes.last == page, "seen \(seen.sizes)")
    }

    @Test func aCardsMenuPreviewIsToldNothing() async {
        let seen = Seen()
        let window = await host(CardMenuPreview(scale: 1, card: CGSize(width: 177, height: 249), radius: 12) { Probe(seen: seen) },
                                size: CGSize(width: 402, height: 874))
        defer { window.isHidden = true }
        #expect(!seen.sizes.isEmpty && seen.sizes.allSatisfy { $0 == nil }, "seen \(seen.sizes)")
    }
}
#endif
