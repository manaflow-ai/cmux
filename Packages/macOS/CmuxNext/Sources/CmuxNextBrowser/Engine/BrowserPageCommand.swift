/// Chromium's own page commands that cmux names in its palette and menus:
/// Save Page As, Cast, Create QR Code and Translate (`browser.savePageAs`,
/// `browser.cast`, `browser.createQRCode`, `browser.translate`). Each runs
/// what the row of Chromium's page menu runs (`cmux_shim_page_command`).
public struct BrowserPageCommand {
    /// `cmux_shim_page_command_t`.
    public enum Command: Int32, CaseIterable, Sendable {
        case saveAs = 1
        case cast = 2
        case qrCode = 3
        case translate = 4

        /// The catalog action that runs each command.
        public var actionID: String {
            switch self {
            case .saveAs: "browser.savePageAs"
            case .cast: "browser.cast"
            case .qrCode: "browser.createQRCode"
            case .translate: "browser.translate"
            }
        }

        /// Every command by its action id, in the catalog's order.
        public static var actions: [(String, Command)] { allCases.map { ($0.actionID, $0) } }
    }

    /// Why a command did not run (the action's refusal).
    public static var unavailable: String {
        String(localized: "browser.pageCommand.unavailable", defaultValue: "This page can't do that now.", bundle: .localizedModule)
    }

    let tab: any BrowserTab

    public init(_ tab: any BrowserTab) {
        self.tab = tab
    }

    /// False when the tab cannot run it now: another engine (WebKit has no
    /// such panels), no page, a shim without the call, or Chromium refused it.
    public func run(_ command: Command) -> Bool {
        guard let tab = tab as? CEFTab, let id = tab.browserID, let call = tab.runtime.shim?.pageCommand else { return false }
        return call(id, command.rawValue) == 1
    }
}
