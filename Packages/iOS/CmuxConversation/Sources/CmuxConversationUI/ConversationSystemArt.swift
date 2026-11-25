#if canImport(UIKit)
import Foundation

/// Messages' artwork: the system ChatKit bundle whose asset catalog the + menu
/// (`SendMenuIcons`) and tapbacks (`TapbackGlyph`) read images from by name,
/// with public API only. nil, the default, draws every one of them in code.
///
/// The app sets it once at launch, before any conversation UI, in every build
/// but App Store. A path into the system's private frameworks in the shipped
/// binary is an App Review 2.5.1 blocker (`app_review_gate.py`
/// `api.private-framework`, the detector of the first 1.0.0 rejection), so this
/// package names no such path and the App Store build never sets one.
public struct ConversationSystemArt {
    public init() {}
    nonisolated(unsafe) public static var bundle: Bundle?
}
#endif
