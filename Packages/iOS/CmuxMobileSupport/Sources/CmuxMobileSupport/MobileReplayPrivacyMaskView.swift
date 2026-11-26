#if os(iOS)
public import UIKit

/// A transparent overlay whose full rectangle is masked by session replay.
///
/// The composition root registers this class in Sentry's required mask list.
/// Keep alpha at one: transparent background pixels must still define a mask.
public final class MobileReplayPrivacyMaskView: UIView {}
#endif
