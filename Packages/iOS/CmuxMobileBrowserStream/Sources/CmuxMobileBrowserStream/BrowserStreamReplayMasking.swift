#if canImport(UIKit)
import UIKit

/// Exports this package's content-rendering view classes for the app's
/// Sentry session-replay mask list without widening their access: streamed
/// browser pixels live in a plain `CALayer`, which replay's text/image
/// masking defaults cannot classify, so the hosting view must be masked by
/// class.
public struct BrowserStreamReplayMasking {
    /// The browser stream view class whose layer-backed pixels must be masked.
    public let maskedViewClasses: [AnyClass]

    public init() {
        self.maskedViewClasses = [BrowserStreamContentView.self]
    }
}
#endif
