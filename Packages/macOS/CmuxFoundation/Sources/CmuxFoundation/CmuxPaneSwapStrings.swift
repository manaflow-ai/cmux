import Foundation

public struct CmuxPaneSwapStrings {
    public init() {}
    public var swapWithSession: String {
        String(
            localized: "paneSwap.swapWithSession",
            defaultValue: "Swap With Session…",
            bundle: .module
        )
    }

    public var terminalPane: String {
        String(
            localized: "paneSwap.terminalPane",
            defaultValue: "Terminal Pane",
            bundle: .module
        )
    }

    public var source: String {
        String(
            localized: "paneSwap.source",
            defaultValue: "Source",
            bundle: .module
        )
    }

    public var swapHere: String {
        String(
            localized: "paneSwap.swapHere",
            defaultValue: "Swap Here",
            bundle: .module
        )
    }
}
