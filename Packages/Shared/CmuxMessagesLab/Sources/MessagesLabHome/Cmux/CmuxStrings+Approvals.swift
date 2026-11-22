extension CmuxStrings {
    static var approvalAllow: String { String(localized: "home.approval.allow", defaultValue: "Allow", table: "CmuxHome", bundle: MessagesLabLocalization.bundle) }
    static var approvalDeny: String { String(localized: "home.approval.deny", defaultValue: "Deny", table: "CmuxHome", bundle: MessagesLabLocalization.bundle) }
    static var approvalAllowed: String { String(localized: "home.approval.allowed", defaultValue: "Allowed", table: "CmuxHome", bundle: MessagesLabLocalization.bundle) }
    static var approvalDenied: String { String(localized: "home.approval.denied", defaultValue: "Denied", table: "CmuxHome", bundle: MessagesLabLocalization.bundle) }
    static var approvalExpired: String { String(localized: "home.approval.stale", defaultValue: "This approval is no longer open", table: "CmuxHome", bundle: MessagesLabLocalization.bundle) }
    static var approvalFailed: String { String(localized: "home.approval.unavailable", defaultValue: "Could not answer. Try again.", table: "CmuxHome", bundle: MessagesLabLocalization.bundle) }
    static var approvalAllowedNotRecorded: String { String(localized: "home.approval.allowedNotRecorded", defaultValue: "Allowed; the card was not updated", table: "CmuxHome", bundle: MessagesLabLocalization.bundle) }
    static var approvalDeniedNotRecorded: String { String(localized: "home.approval.deniedNotRecorded", defaultValue: "Denied; the card was not updated", table: "CmuxHome", bundle: MessagesLabLocalization.bundle) }
}
