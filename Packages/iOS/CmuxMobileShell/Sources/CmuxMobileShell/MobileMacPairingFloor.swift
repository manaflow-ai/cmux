public import CMUXMobileCore
internal import CmuxMobileSupport

/// The hard pairing floor for this iOS build: which saved pairings it can no
/// longer dial until cmux on the Mac updates, and the one phrase naming the
/// Mac version that lifts the floor.
///
/// Every surface that mentions the floor (Computers rows and detail, pairing
/// failures, What's New, setup help, onboarding) reads from here so the story
/// stays consistent and the label is edited in exactly ONE place at the
/// accompanying Mac release cut. The web docs Requirements callout
/// (`web/app/[locale]/(landing)/docs/ios/page.tsx`) and the App Store
/// description state the same floor; bump them in the same release cut.
public enum MobileMacPairingFloor {
    /// Filled in precisely at the accompanying Mac release cut; every floor
    /// surface interpolates it. ONE value to edit at cut time.
    public static var requiredMacVersionLabel: String {
        L10n.string(
            "mobile.macUpdate.requiredVersionLabel",
            defaultValue: "the latest cmux NIGHTLY or cmux RELEASE"
        )
    }

    /// The one-line floor sentence for compact surfaces (What's New footnote,
    /// onboarding method picker and bodies): "Requires <label> on your Mac."
    public static var requiredOnMacSentence: String {
        String(
            format: L10n.string(
                "mobile.macUpdate.requiredOnMacFormat",
                defaultValue: "Requires %@ on your Mac."
            ),
            requiredMacVersionLabel
        )
    }

    /// The way back for users who cannot update the Mac yet: the last iOS
    /// build that still pairs with Macs below the floor.
    public static var revertGuidance: String {
        L10n.string(
            "mobile.macUpdate.revertGuidance",
            defaultValue: """
            Not ready to update your Mac? Stay on (or revert to) cmux BETA TestFlight version \
            1.0.4 (20260817224846), the last version that works with older Macs.
            """
        )
    }

    /// Route-truth for "this pairing needs a Mac update": a stored pairing
    /// that advertises a private-network (Tailscale) route but no Iroh
    /// identity predates the connection protocol this build speaks. This is
    /// the same classification the reconnect path uses before it refuses to
    /// dial and reports ``MobilePairingFailureCategory/macUpdateRequired``,
    /// so ambient surfaces (Computers rows, detail) and the failure surface
    /// can never disagree about which Mac needs the update.
    public static func pairingRequiresMacUpdate(routes: [CmxAttachRoute]) -> Bool {
        routes.contains { $0.kind == .tailscale }
            && !routes.contains { $0.kind == .iroh }
    }
}
