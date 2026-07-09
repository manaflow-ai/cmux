public import SwiftUI

/// A zero-cost background probe that reports its host row's measured height.
///
/// Placed in a `.background` so it adopts the row's size without affecting
/// layout. The height is clamped to a minimum of 1 (a zero height during the
/// first layout pass would make drop-target math divide by zero). The probe
/// reports through ``onHeightChange`` instead of binding to a store, keeping it
/// compliant with the snapshot-boundary rule for rows under a `LazyVStack`.
public struct SidebarRowHeightProbe: View {
    private let onHeightChange: (CGFloat) -> Void

    /// Creates a row-height probe.
    /// - Parameter onHeightChange: Called on appear and whenever the measured
    ///   height changes, with the height clamped to at least 1.
    public init(onHeightChange: @escaping (CGFloat) -> Void) {
        self.onHeightChange = onHeightChange
    }

    public var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    onHeightChange(max(proxy.size.height, 1))
                }
                .onChange(of: proxy.size.height) { _, newHeight in
                    onHeightChange(max(newHeight, 1))
                }
        }
    }
}
