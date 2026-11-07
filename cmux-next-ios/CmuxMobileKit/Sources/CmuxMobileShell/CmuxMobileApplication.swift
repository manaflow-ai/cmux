#if os(iOS)
public import UIKit
import CmuxMobileSupport

/// The app's `UIApplication` (Info.plist `NSPrincipalClass`): a touch on a
/// control that rides a moving view goes to the control where the person
/// sees it (`MobileMovingTapTargets`) before UIKit routes it to the control's
/// end position; every other event goes on unchanged.
@objc(CmuxMobileApplication)
public final class CmuxMobileApplication: UIApplication {
    override public func sendEvent(_ event: UIEvent) {
        if MobileMovingTapTargets.shared.route(event) { return }
        super.sendEvent(event)
    }
}
#endif
