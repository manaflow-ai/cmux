import SwiftUI

struct DiffFailureView: View {
    let kind: DiffScreenErrorKind
    let retry: @MainActor () -> Void

    var body: some View {
        VStack {
            DiffErrorBannerView(kind: kind, retry: retry, dismiss: nil)
            Spacer()
        }
        .background(Color.diffAdaptive(light: .white, dark: .black))
    }
}
