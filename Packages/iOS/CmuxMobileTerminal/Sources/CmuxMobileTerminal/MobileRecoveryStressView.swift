#if canImport(UIKit) && DEBUG
import SwiftUI

/// DEBUG repro harness for repeated render-pipeline recovery teardown.
public struct MobileRecoveryStressView: View {
    private let configuration: MobileRecoveryStressConfiguration

    /// Creates the recovery stress harness view.
    public init(configuration: MobileRecoveryStressConfiguration = MobileRecoveryStressConfiguration()) {
        self.configuration = configuration
    }

    /// The mounted recovery stress harness.
    public var body: some View {
        MobileRecoveryStressRepresentable(configuration: configuration)
            .ignoresSafeArea()
            .background(Color.black)
    }
}
#endif
