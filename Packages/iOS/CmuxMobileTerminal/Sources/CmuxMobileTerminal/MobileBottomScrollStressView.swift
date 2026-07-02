#if canImport(UIKit) && DEBUG
import SwiftUI

/// Which bottom-scroll stress scenario the harness drives.
public enum MobileBottomScrollStressScenario: Sendable {
    /// Composer/keyboard viewport shrink while pinned to scrollback bottom.
    case composerShrink
    /// Authoritative full-replay (`ESC c` snapshot) applied while the viewport
    /// is scrolled into scrollback; the scroll position must survive.
    case fullReplayOffset
}

/// DEBUG repro harness for bottom-scroll viewport bugs.
public struct MobileBottomScrollStressView: View {
    private let scenario: MobileBottomScrollStressScenario

    /// Creates the bottom-scroll stress harness view.
    public init(scenario: MobileBottomScrollStressScenario = .composerShrink) {
        self.scenario = scenario
    }

    /// The mounted stress harness.
    public var body: some View {
        MobileBottomScrollStressRepresentable(scenario: scenario)
            .ignoresSafeArea()
            .background(Color.black)
    }
}
#endif
