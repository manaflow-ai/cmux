#if DEBUG
import SwiftUI

/// DEBUG ONLY: the no-Home prototype's content: the variant picker and its one-line summary, then the app window as
/// that variant lays it out.
struct ChiefNoHomePlaygroundView: View {
    @Bindable var model: ChiefNoHomePlaygroundModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Variant", selection: $model.variant) {
                    ForEach(ChiefNoHomeVariant.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                Text(model.variant.summary).font(.noHomeCaption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).frame(height: 44)
            Divider()
            Group {
                switch model.variant {
                case .threads: ChiefNoHomeThreadsVariant(fixture: model.fixture)
                case .nested: ChiefNoHomeNestedVariant(fixture: model.fixture)
                case .sidePanel: ChiefNoHomeSidePanelVariant(fixture: model.fixture)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif
