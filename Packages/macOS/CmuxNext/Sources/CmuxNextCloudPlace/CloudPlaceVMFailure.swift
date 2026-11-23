import CmuxNextCloud
import Foundation

/// Why a chat's own VM could not start, read from the error the machine create answered with. The wording's choice (`signIn`,
/// `planLimit`, `capacity`, `offline`, or none) is Rust's (`cloud_move_place_vm_failure`); the app localizes it.
public enum CloudPlaceVMFailure {
    /// `signedOut` / `planRequired`: what the app knows of its own errors (a sign-in refusal, an upgrade refusal).
    public static func cause(of error: any Error, signedOut: Bool = false, planRequired: Bool = false) -> String? {
        struct Facts: Encodable { var signedOut: Bool, planRequired: Bool, status: Int?, code: String? }
        struct Reply: Decodable { var cause: String? }
        var facts = Facts(signedOut: signedOut, planRequired: planRequired, status: nil, code: nil)
        switch error as? CloudAPIError {
        case .notSignedIn: facts.signedOut = true
        case .planRequired: facts.planRequired = true
        case .http(let status, let code, _, _, _): (facts.status, facts.code) = (status, code)
        case .transport, .timedOut, .noBackend: facts.code = "offline"
        default: break
        }
        return CloudMoveCore().call("place_vm_failure", facts, as: Reply.self)?.cause
    }
}
