import Foundation
@testable import CmuxNextAgentPane

extension AcpmuxPaneMethods {
    /// Whether the params rule (P1) passes `object` to acpmux exactly as the page wrote it: not
    /// refused, and no key dropped (``checkingParams(_:modeFields:)``). A frame with a key the method
    /// does not list is not refused any more; it goes on without that key.
    static func takesAsSent(_ object: [String: Any]?, modeFields: Set<String>?) -> Bool {
        guard let object else { return true }
        return checkingParams(object, modeFields: modeFields)?.dropped.isEmpty ?? false
    }
}
