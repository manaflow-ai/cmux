#if os(iOS)
import SwiftUI
import UIKit

struct TranscriptActivityProgressView: UIViewRepresentable {
    let color: UIColor

    func makeUIView(context: Context) -> UIActivityIndicatorView {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        indicator.startAnimating()
        return indicator
    }

    func updateUIView(_ indicator: UIActivityIndicatorView, context: Context) {
        indicator.color = color
        indicator.startAnimating()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UIActivityIndicatorView,
        context: Context
    ) -> CGSize? {
        CGSize(width: 12, height: 12)
    }
}
#endif
