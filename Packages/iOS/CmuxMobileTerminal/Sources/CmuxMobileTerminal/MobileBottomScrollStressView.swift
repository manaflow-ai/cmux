#if canImport(UIKit) && DEBUG
import SwiftUI

/// DEBUG repro harness for the bottom-scroll viewport-shrink bug.
public struct MobileBottomScrollStressView: View {
    /// Creates the bottom-scroll stress harness view.
    public init() {}

    /// The mounted stress harness.
    public var body: some View {
        MobileBottomScrollStressRepresentable()
            .ignoresSafeArea()
            .background(Color.black)
    }
}
#endif
