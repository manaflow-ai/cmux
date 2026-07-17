import Foundation

enum BrowserExternalNavigationAction: Equatable {
    case browserFallback(URL)
    case promptToOpenApp(URL)
}
