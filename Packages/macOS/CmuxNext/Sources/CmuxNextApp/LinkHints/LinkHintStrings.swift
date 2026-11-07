import Foundation

/// The words of link hints (`LinkHintController` in CmuxNextBrowser).
enum LinkHintStrings {
    static var noLinks: String {
        String(localized: "linkHints.notice.noLinks", defaultValue: "No links on screen", table: "LinkHints", bundle: .module)
    }

    static var engine: String {
        String(localized: "linkHints.refusal.engine", defaultValue: "Link hints work in Chromium pages.", table: "LinkHints", bundle: .module)
    }
}
