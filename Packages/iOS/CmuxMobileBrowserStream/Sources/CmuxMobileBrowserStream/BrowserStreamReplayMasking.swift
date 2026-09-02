#if canImport(UIKit)
import UIKit

/// Exports this package's content-rendering view classes for the app's
/// Sentry session-replay mask list without widening their access: streamed
/// browser pixels live in a plain `CALayer`, which replay's text/image
/// masking defaults cannot classify, so the hosting view must be masked by
/// class.
public enum BrowserStreamReplayMasking {
    public static var maskedViewClasses: [AnyClass] {
        [BrowserStreamContentView.self]
    }
}
#endif
