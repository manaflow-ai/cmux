#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

/// A grid card's map of its tab's screen on the Mac: each shown pane outlined at its real
/// proportions, the tab's own pane filled (`WorkspaceLayout.splitMap(ofTab:)`). Drawn in page
/// points, like the card's chips, so it scales down with the card.
///
/// A gallery variant, off by default (Leo, 2026-11-22: "if youre gonna do the safari tab
/// layout... you should be able to see where the splits are, maybe"): DEBUG builds show it with
/// `CMUX_TABS_CARD_SPLIT_MAP=1`.
struct TabSplitMapBadge: View {
    let map: TabSplitMap
    /// The badge's width in page points.
    var width: CGFloat = 112

    /// The variant is on (DEBUG, `CMUX_TABS_CARD_SPLIT_MAP=1`).
    static let isEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["CMUX_TABS_CARD_SPLIT_MAP"] == "1"
        #else
        false
        #endif
    }()

    var body: some View {
        let size = CGSize(width: width, height: width / max(map.aspect, 0.1))
        let gap: CGFloat = 3
        ZStack(alignment: .topLeading) {
            ForEach(map.cells, id: \.pane) { cell in
                let own = cell.pane == map.pane
                let rect = CGRect(x: cell.rect.minX * size.width, y: cell.rect.minY * size.height,
                                  width: cell.rect.width * size.width, height: cell.rect.height * size.height)
                    .insetBy(dx: gap / 2, dy: gap / 2)
                // White, as the card's chips: the app's accent drew no fill on a terminal's black
                // (fleet step a29c8df1aed467b35a008f43, video: only the other pane's outline showed).
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(own ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.12)))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(.white.opacity(own ? 1 : 0.55), lineWidth: 1.5)
                    }
                    .frame(width: max(rect.width, 0), height: max(rect.height, 0))
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .padding(5)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// "Pane 2 of 3 in a split" for VoiceOver: the card's accessibility value
    /// (`WorkspaceTabsSource.cardAccessibilityValue(for:)`), since TabsKit makes a card one element
    /// and nothing drawn inside it is read.
    static func label(_ map: TabSplitMap) -> String {
        let index = (map.cells.firstIndex { $0.pane == map.pane } ?? 0) + 1
        return "Pane \(index) of \(map.cells.count) in a split"
    }
}
#endif
