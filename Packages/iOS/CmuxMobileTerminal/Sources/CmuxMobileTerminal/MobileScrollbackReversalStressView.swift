#if canImport(UIKit) && DEBUG
import SwiftUI
import UIKit

/// DEBUG repro harness for fast local scrollback reversals through numbered rows.
public struct MobileScrollbackReversalStressView: View {
    /// Creates the scrollback reversal stress harness view.
    public init() {}

    /// The mounted stress harness.
    public var body: some View {
        MobileScrollbackReversalStressRepresentable()
            .ignoresSafeArea()
            .background(Color.black)
    }
}
#endif
