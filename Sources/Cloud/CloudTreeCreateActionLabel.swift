import CmuxCloud
import SwiftUI

/// The noninteractive label shared by a create row and its SwiftUI button.
struct CloudTreeCreateActionLabel: View {
    let action: CloudTreeCreateAction
    let style: CloudTreeStyle
    var isHovered = false

    var body: some View {
        CloudTreeLeafRow(
            style: style,
            icon: "plus",
            tint: .secondary,
            title: action.title,
            titleWeight: .regular,
            titleDimmed: !isHovered
        )
    }
}
