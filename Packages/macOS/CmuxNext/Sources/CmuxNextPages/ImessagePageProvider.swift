public import CmuxNextSettings
public import Foundation

public extension PageDescriptor {
    /// The Messages mirror page (webviews/src/pages/imessage): this Mac's Messages conversations,
    /// read only, from the daemon's `imessage.*` ops (`cmux.imessage.` through the daemon relay;
    /// the daemon's page-router entry `imessage` decides what it may read). Its one native op runs
    /// Settings… at the mirror's toggle; ``ImessagePrivacyPageRoute`` opens Full Disk Access.
    static let imessage = PageDescriptor(
        id: "cmux.imessage", resource: "imessage", namespaces: ["cmux.imessage."],
        nativeOps: [PageNativeOp.actionRun], actions: ["openSettings"])
}

/// `cmux.imessage.privacy.open {}`: opens System Settings > Privacy & Security > Full Disk Access,
/// the one grant the mirror needs (it goes to the cmux app, which spawns the daemon). The page names
/// no URL: the pane is fixed here. Only the person's click on the page opens it.
@MainActor
public final class ImessagePrivacyPageRoute: PageProvider {
    public nonisolated static let prefix = "cmux.imessage.privacy."
    /// System Settings at Full Disk Access.
    public nonisolated static let fullDiskAccessURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    private let open: @MainActor (URL) -> Void

    /// - Parameter open: Opens a URL (the app passes `NSWorkspace.shared.open`).
    public init(open: @escaping @MainActor (URL) -> Void) {
        self.open = open
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.prefix + "open" else { throw PageError.unknownOp(op) }
        guard context.page == PageDescriptor.imessage.id, context.userGesture else {
            throw PageError(code: "cmux.imessage.user_only", message: ImessagePage.userOnly)
        }
        open(Self.fullDiskAccessURL)
        return .object([:])
    }
}

/// The Messages mirror tab's strings.
public enum ImessagePage {
    /// The tab's title.
    public static var title: String { t("imessage.tab.title", "Messages Mirror") }
    static var userOnly: String {
        t("imessage.privacy.userOnly", "Only you can open Full Disk Access settings, with a click on the page.")
    }

    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
