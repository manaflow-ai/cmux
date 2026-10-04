public import AppKit
public import Foundation

/// What a native confirmation sheet asks before a page call that grants or removes something
/// (install, uninstall, update, grant; delete, billing, firewall, publication for other pages).
/// Page JS cannot prove a gesture (coordinator Q4), so these calls always pass this sheet; only an
/// approved call reaches the owner as the user's own.
public nonisolated struct PageConfirmation: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case install, uninstall, update, grant, delete, custom
    }

    /// One scope the app asks for, with its class from scope-classes.json and the app's reason.
    public struct Scope: Sendable, Hashable {
        public var scope: String
        public var reason: String
        /// `standard`, `sensitive` or `restricted`.
        public var risk: String

        public init(scope: String, reason: String, risk: String) {
            self.scope = scope
            self.reason = reason
            self.risk = risk
        }
    }

    public var kind: Kind
    /// The subject's display name (the app, the machine).
    public var name: String
    public var scopes: [Scope]
    /// A web app's start URL and the other origins it opens (app-platform.md section 16).
    public var webURL: String?
    public var webOrigins: [String]
    /// For `custom` and `delete`: the sentence under the title.
    public var detail: String?

    public init(kind: Kind, name: String, scopes: [Scope] = [], webURL: String? = nil, webOrigins: [String] = [], detail: String? = nil) {
        self.kind = kind
        self.name = name
        self.scopes = scopes
        self.webURL = webURL
        self.webOrigins = webOrigins
        self.detail = detail
    }

    /// The sheet's title.
    public var title: String {
        switch kind {
        case .install: String(format: PageStrings.installTitle, name)
        case .uninstall: String(format: PageStrings.uninstallTitle, name)
        case .update: String(format: PageStrings.updateTitle, name)
        case .grant: String(format: PageStrings.grantTitle, name, scopes.map(\.scope).joined(separator: ", "))
        case .delete: String(format: PageStrings.deleteTitle, name)
        case .custom: name
        }
    }

    /// The confirm button.
    public var confirmTitle: String {
        switch kind {
        case .install: PageStrings.install
        case .uninstall: PageStrings.remove
        case .update: PageStrings.update
        case .grant: PageStrings.allow
        case .delete: PageStrings.delete
        case .custom: PageStrings.continueTitle
        }
    }

    /// Whether the confirm button is destructive.
    public var isDestructive: Bool { kind == .uninstall || kind == .delete }

    /// The body lines: the detail, the scopes (riskiest first, with their class), the web origins.
    public var lines: [String] {
        var lines: [String] = []
        if let detail { lines.append(detail) }
        let order = ["restricted": 0, "sensitive": 1, "standard": 2]
        let sorted = scopes.sorted { (order[$0.risk] ?? 3, $0.scope) < (order[$1.risk] ?? 3, $1.scope) }
        if !sorted.isEmpty, kind != .grant {
            lines.append(PageStrings.asksFor)
            for scope in sorted { lines.append("• \(scope.scope) (\(PageStrings.risk(scope.risk))): \(scope.reason)") }
        } else if kind == .grant {
            for scope in sorted { lines.append("\(PageStrings.risk(scope.risk)): \(scope.reason)") }
        }
        if let webURL {
            lines.append(PageStrings.opensWeb)
            for url in [webURL] + webOrigins { lines.append("• \(url)") }
        }
        return lines
    }
}

/// Shows a confirmation and answers whether the person approved it.
@MainActor
public protocol PageConfirmationPresenter: AnyObject {
    func confirm(_ confirmation: PageConfirmation, anchor: NSView?) async -> Bool
}

/// The AppKit sheet: an alert attached to the page's window (a free-standing alert when the page
/// has no window), confirm button destructive for removals, Cancel the default for them.
@MainActor
public final class AlertPageConfirmationPresenter: PageConfirmationPresenter {
    public init() {}

    public func confirm(_ confirmation: PageConfirmation, anchor: NSView?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.lines.joined(separator: "\n")
        alert.alertStyle = confirmation.isDestructive ? .warning : .informational
        let confirm = alert.addButton(withTitle: confirmation.confirmTitle)
        confirm.hasDestructiveAction = confirmation.isDestructive
        let cancel = alert.addButton(withTitle: PageStrings.cancel)
        if confirmation.isDestructive {
            confirm.keyEquivalent = ""
            cancel.keyEquivalent = "\r"
        }
        guard let window = anchor?.window else { return alert.runModal() == .alertFirstButtonReturn }
        let response = await alert.beginSheetModal(for: window)
        return response == .alertFirstButtonReturn
    }
}
