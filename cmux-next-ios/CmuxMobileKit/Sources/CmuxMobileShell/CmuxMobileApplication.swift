#if os(iOS)
public import UIKit
public import CmuxMobileSupport

/// The app's `UIApplication` (Info.plist `NSPrincipalClass`): a touch on a
/// control that rides a moving view goes to the control where the person
/// sees it (`MobileMovingTapTargets`) before UIKit routes it to the control's
/// end position; every other event goes on unchanged.
@objc(CmuxMobileApplication)
public final class CmuxMobileApplication: UIApplication, MobileMovingTapTargets.Routing {
    public let movingTapTargets = MobileMovingTapTargets()

    override public func sendEvent(_ event: UIEvent) {
        if movingTapTargets.route(event) { return }
        super.sendEvent(event)
    }
}
#endif
