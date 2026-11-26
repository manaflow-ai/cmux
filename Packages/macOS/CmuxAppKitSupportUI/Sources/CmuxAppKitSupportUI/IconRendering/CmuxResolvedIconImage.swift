public import SwiftUI

/// SwiftUI bridge for appearance-resolved AppKit icons.
@MainActor
public struct CmuxResolvedIconImage: NSViewRepresentable {
    public let request: CmuxResolvedIconRequest?

    /// Creates a SwiftUI icon backed by ``CmuxResolvedIconImageView``.
    public init(request: CmuxResolvedIconRequest?) {
        self.request = request
    }

    public func makeNSView(context: Context) -> CmuxResolvedIconImageView {
        CmuxResolvedIconImageView(frame: .zero)
    }

    public func updateNSView(_ nsView: CmuxResolvedIconImageView, context: Context) {
        nsView.apply(request)
    }
}
