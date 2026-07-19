import CMUXMobileCore
import Foundation

struct MobileHostRouteSnapshot: Sendable {
    let routes: [CmxAttachRoute]

    var payload: [[String: Any]] {
        routes.mobileHostJSONObjects(for: .authenticated)
    }
}
