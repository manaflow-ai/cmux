#if canImport(UIKit)
import SwiftUI
import UIKit

struct MobileDiagnosticsActivityView: UIViewControllerRepresentable {
    let item: MobileDiagnosticsActivityItem

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [item.text], applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
#endif
