import Foundation

extension CMUXCLI {
    nonisolated struct CmuxUseCheckoutResult {
        let url: URL
        let action: String
    }

    nonisolated struct CmuxUseInstallResult {
        let url: URL
        let action: String
        let mode: String
    }

    nonisolated struct CmuxUseLaunchScript {
        let initialCommand: String
        let url: URL
    }
}
