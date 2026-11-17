public import Foundation

/// A code or link the prompt bar may offer on one tab. Built only by
/// ``VerificationOfferPolicy``; held only by ``VerificationInbox``, in
/// memory. Its descriptions never show the code or link.
public nonisolated struct VerificationOffer: Sendable, Hashable {
    public let emailID: String
    public let tab: BrowserTabID
    /// The registrable domain of the sender's address ("github.com"), shown as "from github.com".
    /// It equals ``pageSite`` unless a reviewed sender map entry admitted the email
    /// (``VerificationSenderMap``: codes for chatgpt.com come from openai.com).
    public let senderSite: String
    /// The registrable domain of the page the offer was made on: the tab must still show it when
    /// the person accepts.
    public let pageSite: String
    /// The page's origin when the offer was made ("https://github.com"): the
    /// tab must still show it when the person clicks.
    public let pageOrigin: String
    /// The code to fill, if the email had exactly one.
    public let code: String?
    /// The same-site verification link to open, if the email had exactly one.
    public let link: URL?
    /// When the offer stops being shown (the email's arrival plus the window).
    public let expiresAt: Date

    public init(emailID: String, tab: BrowserTabID, senderSite: String, pageSite: String? = nil, pageOrigin: String,
                code: String?, link: URL?, expiresAt: Date) {
        self.emailID = emailID
        self.tab = tab
        self.senderSite = senderSite
        self.pageSite = pageSite ?? senderSite
        self.pageOrigin = pageOrigin
        self.code = code
        self.link = link
        self.expiresAt = expiresAt
    }
}

extension VerificationOffer: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "VerificationOffer(email: \(emailID), tab: \(tab), site: \(senderSite), code: \(code == nil ? "no" : "yes"), link: \(link == nil ? "no" : "yes"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["emailID": emailID, "tab": tab, "senderSite": senderSite, "pageSite": pageSite, "pageOrigin": pageOrigin], displayStyle: .struct)
    }
}
