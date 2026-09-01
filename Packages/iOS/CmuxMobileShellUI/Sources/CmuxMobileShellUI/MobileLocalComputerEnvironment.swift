#if os(iOS)
import SwiftUI

/// A phone-owned computer that does not use the paired-Mac RPC protocol.
///
/// The shell UI only knows how to present the computer row and destination. The
/// concrete implementation lives in the composition-root feature module (where
/// the iSH kernel package is available). Keeping this protocol here avoids a
/// dependency cycle from `CmuxMobileShellUI` back to the app feature module and
/// prevents a local terminal from being represented as a fake Mac connection.
@MainActor
public protocol MobileLocalComputerProviding: AnyObject {
    /// User-facing computer name.
    var title: String { get }
    /// Short explanatory line shown below the computer name.
    var subtitle: String { get }
    /// SF Symbol used for the computer avatar.
    var symbolName: String { get }
    /// Whether this build can present the local computer.
    var isAvailable: Bool { get }
    /// Builds the destination pushed by the Computers list.
    func makeDestination() -> AnyView
}

/// Environment values cross SwiftUI's concurrency boundary. The provider is
/// main-actor isolated, so retain it behind a deliberately narrow unchecked
/// reference wrapper, matching the other app-root controller environments.
private struct MobileLocalComputerProviderReference: @unchecked Sendable {
    let provider: (any MobileLocalComputerProviding)?
}

private struct MobileLocalComputerProviderEnvironmentKey: EnvironmentKey {
    static let defaultValue = MobileLocalComputerProviderReference(provider: nil)
}

public extension EnvironmentValues {
    /// The app-owned local computer presenter, when this target supports one.
    var mobileLocalComputerProvider: (any MobileLocalComputerProviding)? {
        get { self[MobileLocalComputerProviderEnvironmentKey.self].provider }
        set {
            self[MobileLocalComputerProviderEnvironmentKey.self] =
                MobileLocalComputerProviderReference(provider: newValue)
        }
    }
}

public extension View {
    /// Injects the phone-owned computer presenter into a shell subtree.
    func mobileLocalComputerProvider(
        _ provider: (any MobileLocalComputerProviding)?
    ) -> some View {
        environment(\.mobileLocalComputerProvider, provider)
    }
}
#endif
