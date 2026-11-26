public import AppKit

extension CmuxDialogCenter {
    /// The allow button's id in ``askConsent(title:lines:allow:deny:identifier:)``.
    public static let consentAllowButton = "consent.allow"

    /// Asks the person one yes-or-no consent question over the app (no window needed) and answers whether
    /// they chose `allow`. The allow button takes only the person's own click (``CmuxDialogButton/personOnly``),
    /// so no key, script or automation answers yes. Cancelling the calling task dismisses the dialog, which
    /// is a no: a caller's deadline closes it.
    public func askConsent(title: String, lines: [String], allow: String, deny: String, identifier: String) async -> Bool {
        let spec = CmuxDialogSpec(
            usesTransientMaterial: true, title: title, lines: lines,
            buttons: [CmuxDialogButton(id: "consent.deny", title: deny, role: .cancel),
                      CmuxDialogButton(id: Self.consentAllowButton, title: allow, role: .default, personOnly: true)],
            identifier: identifier)
        NSApplication.shared.requestUserAttention(.informationalRequest)
        let answer = await present(spec, in: .app)
        return !answer.isDismissal && answer.button == Self.consentAllowButton
    }
}
