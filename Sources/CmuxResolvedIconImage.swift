import AppKit
import SwiftUI

/// SwiftUI bridge for an appearance-resolved AppKit icon.
@MainActor
struct CmuxResolvedIconImage: NSViewRepresentable {
    let request: CmuxResolvedIconRequest?

    init(request: CmuxResolvedIconRequest?) {
        self.request = request
    }

    init(
        systemName: String,
        size: CGFloat,
        tintColor: NSColor? = nil,
        weight: NSFont.Weight = .regular,
        accessibilityDescription: String? = nil
    ) {
        self.init(request: CmuxResolvedIconRequest(
            source: .systemSymbol(name: systemName, accessibilityDescription: accessibilityDescription),
            size: NSSize(width: size, height: size),
            tintColor: tintColor,
            symbolWeight: weight,
            accessibilityDescription: accessibilityDescription
        ))
    }

    func makeNSView(context: Context) -> CmuxResolvedIconImageView {
        CmuxResolvedIconImageView(frame: .zero)
    }

    func updateNSView(_ nsView: CmuxResolvedIconImageView, context: Context) {
        nsView.apply(request)
    }
}
