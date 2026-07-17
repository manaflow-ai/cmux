import SwiftUI

struct DiffFailureView: View {
    let kind: DiffScreenErrorKind
    let retry: @MainActor () -> Void
    let useWorkingTree: (@MainActor () -> Void)?

    var body: some View {
        VStack {
            DiffErrorBannerView(
                kind: kind,
                retry: retry,
                useWorkingTree: useWorkingTree,
                dismiss: nil
            )
            Spacer()
        }
        .background(Color.diffAdaptive(light: .white, dark: .black))
    }
}
