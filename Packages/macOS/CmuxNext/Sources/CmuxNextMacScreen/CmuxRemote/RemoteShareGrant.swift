public import CmuxNextSettings
public import Foundation

/// SECURITY: the account that chose Always Allow on "Share This Mac?". `remote.shareWithoutAsking`
/// lets a share request skip the dialog only while the signed-in cmux account is the one whose
/// person clicked Always Allow on this Mac (``covers``). Signing out, another account, or this Mac
/// leaving the device hub forgets the grant and turns the setting off (``accountChanged(_:)``); the
/// setting going off forgets it too (``settingChanged(on:)``), so a later file edit turning it back on
/// skips nothing.
///
/// The record lives beside the setting, not in it, like Hang Reports' consent record: a cmux-next.json
/// that turns the setting on (an edit, a copied file) gets no record, so it skips nothing until the
/// person clicks Always Allow. A setting a managing team pins on (MDM) is the team's own choice and
/// counts without a record.
///
/// Not a boundary against this user's own processes: one that can run `defaults write` for this app
/// can write the record too, as it can Hang Reports' record. It keeps a copied or edited settings
/// file, and another account, from skipping the dialog.
@MainActor
public final class RemoteShareGrant {
    static let defaultsKey = "cmux.remote.shareWithoutAsking.account"

    private let defaults: UserDefaults
    /// Turns `remote.shareWithoutAsking` off; the app sets it (tests record the calls).
    public var turnOff: @MainActor () -> Void = {}
    /// The signed-in account's user id now; nil while signed out or out of the hub.
    public private(set) var account: String?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The account that clicked Always Allow, if any.
    var grantedTo: String? { defaults.string(forKey: Self.defaultsKey) }

    /// Whether a share request may skip the dialog: the setting is on, and either a managing team
    /// pinned it or this account's person clicked Always Allow.
    public func covers(settingOn: Bool, managed: Bool) -> Bool {
        guard settingOn else { return false }
        if managed { return true }
        guard let account else { return false }
        return grantedTo == account
    }

    /// The person clicked Always Allow: the grant belongs to the signed-in account.
    public func record() {
        guard let account else { return }
        defaults.set(account, forKey: Self.defaultsKey)
    }

    /// `remote.shareWithoutAsking`'s value now: off forgets the grant (no turnOff: it is off already).
    public func settingChanged(on: Bool) {
        if !on { defaults.removeObject(forKey: Self.defaultsKey) }
    }

    /// The signed-in account (nil: signed out, or this Mac left the hub). A grant another account made
    /// is forgotten and the setting turned off; the first read after launch counts too.
    public func accountChanged(_ account: String?) {
        self.account = account
        guard let granted = grantedTo, granted != account else { return }
        defaults.removeObject(forKey: Self.defaultsKey)
        turnOff()
    }

    /// Turns `remote.shareWithoutAsking` off as the app (the person's own sign-out or account change).
    public static func turnOff(_ settings: SettingsController) async {
        guard let descriptor = SettingsSchema.descriptor(for: RemoteSettings.shareWithoutAskingPath) else { return }
        try? await settings.setSetting(descriptor, to: .bool(false), by: .user)
    }
}
