import Foundation
import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileTerminalViewportFitTests {
    @Test func decodesMacSnakeCaseWireShape() throws {
        let json = Data(#"""
        {
          "effective": {"columns": 80, "rows": 24},
          "client": {"columns": 120, "rows": 40},
          "is_current_client_limiting": true
        }
        """#.utf8)

        let fit = try JSONDecoder().decode(MobileTerminalViewportFit.self, from: json)

        #expect(fit.effective == MobileTerminalViewportSize(columns: 80, rows: 24))
        #expect(fit.client == MobileTerminalViewportSize(columns: 120, rows: 40))
        #expect(fit.isCurrentClientLimiting)
        #expect(fit.shouldDrawVisibleAreaRightBorder)
        #expect(fit.shouldDrawVisibleAreaBottomBorder)
        #expect(fit.shouldDrawVisibleAreaBorder)
    }

    @Test func roundTripsThroughSnakeCaseKey() throws {
        let original = MobileTerminalViewportFit(
            effective: MobileTerminalViewportSize(columns: 100, rows: 30),
            client: nil,
            isCurrentClientLimiting: false
        )

        let encoded = try JSONEncoder().encode(original)
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["is_current_client_limiting"] as? Bool == false)

        let decoded = try JSONDecoder().decode(MobileTerminalViewportFit.self, from: encoded)
        #expect(decoded == original)
        #expect(!decoded.shouldDrawVisibleAreaBorder)
    }

    @Test func clampsViewportDimensionsToAtLeastOne() {
        let size = MobileTerminalViewportSize(columns: 0, rows: -5)
        #expect(size.columns == 1)
        #expect(size.rows == 1)
    }
}
