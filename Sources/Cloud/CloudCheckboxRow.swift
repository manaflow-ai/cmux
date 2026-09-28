import CmuxFoundation
import SwiftUI

/// A checkbox whose title is a sibling `Text`, not the `Toggle` label.
///
/// The Cloud sheets size their windows from SwiftUI (`sizingOptions =
/// [.preferredContentSize]`). A labeled `Toggle` is an `NSButton` checkbox
/// whose title makes its fitting size depend on the width it is offered, and
/// while a sheet animates open that feedback runs AppKit past its
/// update-constraints pass limit and it throws, aborting the app. A
/// label-less checkbox has a fixed size, so the row lays out once.
struct CloudCheckboxRow<Detail: View>: View {
    let title: String
    @Binding var isOn: Bool
    var fontSize: CGFloat = 13
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Toggle(isOn: $isOn) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(title)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .cmuxFont(size: fontSize)
                    .contentShape(Rectangle())
                    .onTapGesture { isOn.toggle() }
                    .accessibilityHidden(true)
                detail()
            }
        }
    }
}

extension CloudCheckboxRow where Detail == EmptyView {
    init(title: String, isOn: Binding<Bool>, fontSize: CGFloat = 13) {
        self.init(title: title, isOn: isOn, fontSize: fontSize) { EmptyView() }
    }
}
