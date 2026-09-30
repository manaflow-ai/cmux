import CmuxCloud
import SwiftUI

/// A hit-testable create row whose action remains visible without hover.
struct CloudTreeCreateActionView: View {
    let action: CloudTreeCreateAction
    let nodeActions: CloudTreeNodeActions
    let style: CloudTreeStyle

    var body: some View {
        Button {
            action.perform(nodeActions)
        } label: {
            CloudTreeCreateActionLabel(action: action, style: style)
                // Keep the glyph in the same leading icon slot as the owning
                // category. The normal tree rows do not have a leading button
                // inset; only the trailing edge needs breathing room for the
                // action background.
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, minHeight: style.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(action.title)
        .accessibilityLabel(action.title)
        .accessibilityIdentifier(action.accessibilityIdentifier)
    }
}
