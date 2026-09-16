import SwiftUI

/// A single resource or cost row inside a machine's Resources section.
struct CloudTreeMachineResourceRowContent: View {
    let row: CloudTreeMachineResourceRow
    var style: CloudTreeStyle = CloudTreeStyleStore.current

    var body: some View {
        CloudTreeLeafRow(
            style: style,
            icon: row.icon,
            tint: CloudTreeIconPalette.machine,
            title: row.title,
            detail: row.detail
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}
