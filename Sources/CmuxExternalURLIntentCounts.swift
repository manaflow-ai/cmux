import Foundation

extension AppDelegate {
    struct CmuxExternalURLIntentCounts {
        var run = 0
        var ssh = 0
        var navigation = 0
        var text = 0

        var total: Int {
            run + ssh + navigation + text
        }
    }
}
