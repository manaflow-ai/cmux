#if canImport(UIKit)
import SwiftUI
import UIKit

struct MobileDiagnosticsActivityView: UIViewControllerRepresentable {
    struct Item: Identifiable {
        let id = UUID()
        let text: String
    }

    let item: Item

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [item.text], applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
#endif
