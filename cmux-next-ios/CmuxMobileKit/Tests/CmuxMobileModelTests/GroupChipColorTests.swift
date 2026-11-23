import CmuxMobileModel
import Foundation
import Testing

/// A tab group's chip on a tab card drew SwiftUI's system colors (raw yellow, red, …) under a
/// white 26 pt name: on yellow the name was near invisible, and the colors were not the Mac's.
/// It now draws the Mac's dark chip fill (`GroupColor` role `fill`) from its vibrant palette.
@Suite struct GroupChipColorTests {
    /// WCAG contrast ratio of white over `rgb`.
    static func whiteContrast(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double(rgb >> shift & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        return 1.05 / (luminance + 0.05)
    }

    /// The Mac's numbers: yellow F5BA14 taken 55% toward 1C1C1E.
    @Test func darkFillIsTheMacs() {
        #expect(WorkspaceColor.darkFill(WorkspaceColor.yellow.vibrant(dark: true)) == 0x7E631A)
        #expect(WorkspaceColor.darkFill(0x1C1C1E) == 0x1C1C1E)
    }

    /// Every group color's chip carries its white name at AA contrast (4.5:1); system yellow
    /// (FFCC00) under the same name was about 1.5:1.
    @Test func everyChipReadsWhiteText() {
        #expect(Self.whiteContrast(0xFFCC00) < 2)
        for color in WorkspaceColor.allCases {
            let fill = WorkspaceColor.darkFill(color.vibrant(dark: true))
            #expect(Self.whiteContrast(fill) >= 4.5, "\(color): \(String(fill, radix: 16)) \(Self.whiteContrast(fill))")
        }
    }
}
