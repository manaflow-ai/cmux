import CmuxCloud
import CmuxFoundation
import SwiftUI

/// A top-level section header (Cloud Machines, My Devices): the section's
/// identity glyph in the shared leading icon slot, then the shared group label.
/// The glyph names the kind of every row below it, so those rows carry none.
struct CloudTreeSectionHeaderRow<Label: View>: View {
    let style: CloudTreeStyle
    let symbol: String
    @ViewBuilder var label: () -> Label
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification

    var body: some View {
        HStack(alignment: .center, spacing: GlobalFontMagnification.scaledSize(style.iconGap, percent: magnification)) {
            if style.iconSlot > 0 {
                CloudTreeRowIcon(style: style, systemName: symbol, tint: CloudTreeIconPalette.machine)
            }
            label()
        }
    }
}
