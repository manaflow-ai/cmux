import Foundation

public struct CmuxPaneSwapStrings {
    public init() {}
    public var swapWithSession: String {
        CmuxFoundationLocalization.string(
            "paneSwap.swapWithSession",
            defaultValue: "Swap With Session…"
        )
    }

    public var terminalPane: String {
        CmuxFoundationLocalization.string(
            "paneSwap.terminalPane",
            defaultValue: "Terminal Pane"
        )
    }

    public var source: String {
        CmuxFoundationLocalization.string(
            "paneSwap.source",
            defaultValue: "Source"
        )
    }

    public var swapHere: String {
        CmuxFoundationLocalization.string(
            "paneSwap.swapHere",
            defaultValue: "Swap Here"
        )
    }
}
