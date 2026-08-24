#if os(iOS)
import Foundation

/// Marketing links the app hands people during setup guidance.
enum CmuxMarketingLink {
    /// The cmux homepage, which carries the Mac download.
    static let download = URL(string: "https://cmux.com")!
}
#endif
