import CmuxNextIcons
import SwiftUI

/// A label whose icon is a registry icon at the row size of its
/// `textSize` point text; the caller sets the font.
struct FeedIconLabel: View {
    let title: String
    let icon: IconName
    let textSize: CGFloat

    init(_ title: String, icon: IconName, textSize: CGFloat) {
        self.title = title
        self.icon = icon
        self.textSize = textSize
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Icon(icon, size: .iconRowSize(forLabelPointSize: textSize))
        }
    }
}
