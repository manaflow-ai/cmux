import AppKit
import CmuxAppKitSupportUI
import Testing
@testable import CmuxUpdaterUI

/// Updater symbols must use the shared AppKit renderer so a transient blank
/// SwiftUI draw cannot erase the badge icon on Intel/macOS 15.
@MainActor
@Suite("Update badge icon")
struct UpdateBadgeTests {
    @Test func hostedRequestUsesTintedAppKitSymbol() throws {
        let request = UpdateBadge.hostedIconRequest(
            systemName: "shippingbox.fill",
            tintColor: .white
        )

        #expect(request.size == NSSize(width: 14, height: 14))
        #expect(request.symbolPointSize == 13)
        #expect(request.symbolWeight == .semibold)
        #expect(request.tintColor == .white)
        guard case .systemSymbol(let sourceName, _) = request.source else {
            Issue.record("expected a system-symbol source")
            return
        }
        #expect(sourceName == "shippingbox.fill")
        guard case .systemSymbol(let fallbackName, _)? = request.fallbackSource else {
            Issue.record("expected a same-symbol fallback for transient blank draws")
            return
        }
        #expect(fallbackName == sourceName)
    }

    @Test func hostedRequestRendersVisiblePixels() throws {
        let request = UpdateBadge.hostedIconRequest(
            systemName: "shippingbox.fill",
            tintColor: .white
        )
        let appearance = try #require(NSAppearance(named: .aqua))
        let image = try #require(CmuxResolvedIconRenderer().image(for: request, appearance: appearance))
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)

        var visiblePixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 {
                    visiblePixels += 1
                }
            }
        }
        #expect(visiblePixels > 0)
    }
}
