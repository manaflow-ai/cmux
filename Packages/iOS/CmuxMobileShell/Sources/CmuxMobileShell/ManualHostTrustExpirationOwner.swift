import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

/// Identifies the foreground connection that owns one manual-host trust deadline.
struct ManualHostTrustExpirationOwner: Equatable {
    let scope: MobileManualHostTrustScope
    let route: CmxAttachRoute
    let client: MobileCoreRPCClient
    let generation: UUID
    let authScope: MobileRPCAuthScope

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope
            && lhs.route == rhs.route
            && lhs.client === rhs.client
            && lhs.generation == rhs.generation
            && lhs.authScope == rhs.authScope
    }
}
