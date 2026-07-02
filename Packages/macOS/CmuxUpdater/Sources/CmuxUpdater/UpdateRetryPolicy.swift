import Foundation
@preconcurrency import Sparkle

/// Classifies transient update download failures and maps them to bounded retry delays.
struct UpdateRetryPolicy {
    /// The retry delays for consecutive transient failures.
    let retryDelays: [TimeInterval]

    /// Creates a retry policy.
    init(retryDelays: [TimeInterval] = [1, 3, 8]) {
        self.retryDelays = retryDelays
    }

    /// The number of automatic retries allowed for one update operation.
    var maximumRetryCount: Int {
        retryDelays.count
    }

    /// Returns the retry delay for a 1-based failure number, or `nil` if this error should
    /// surface immediately.
    func delay(afterFailureNumber failureNumber: Int, for error: any Swift.Error) -> TimeInterval? {
        guard isTransientDownloadError(error) else { return nil }
        guard failureNumber > 0, failureNumber <= retryDelays.count else { return nil }
        return retryDelays[failureNumber - 1]
    }

    /// Whether the error is a Sparkle download failure caused by a transient network/server
    /// condition such as GitHub's release CDN returning HTTP 504.
    func isTransientDownloadError(_ error: any Swift.Error) -> Bool {
        let errors = relatedErrors(startingAt: error as NSError)
        guard errors.contains(where: isSparkleDownloadError) else { return false }
        return errors.contains(where: hasTransientNetworkSignal)
    }

    private func isSparkleDownloadError(_ error: NSError) -> Bool {
        error.domain == SUSparkleErrorDomain && error.code == 2001
    }

    private func hasTransientNetworkSignal(_ error: NSError) -> Bool {
        if isTransientURLLoadingError(error) {
            return true
        }
        return transientHTTPStatusCode(in: error).map(isTransientHTTPStatusCode) ?? false
    }

    private func isTransientURLLoadingError(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorTimedOut,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotLoadFromNetwork:
            return true
        default:
            return false
        }
    }

    private func isTransientHTTPStatusCode(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private func transientHTTPStatusCode(in error: NSError) -> Int? {
        let text = [
            error.localizedDescription,
            (error.userInfo[NSLocalizedFailureReasonErrorKey] as? String) ?? "",
            (error.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String) ?? "",
        ].joined(separator: "\n")

        return firstTransientHTTPStatusCode(in: text)
    }

    private func firstTransientHTTPStatusCode(in text: String) -> Int? {
        let patterns = [
            #"\((\d{3})\)"#,
            #"(?i)\bHTTP\s+(\d{3})\b"#,
        ]
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: text, range: fullRange)
            for match in matches where match.numberOfRanges > 1 {
                let status = nsText.substring(with: match.range(at: 1))
                guard let statusCode = Int(status) else { continue }
                guard isTransientHTTPStatusCode(statusCode) else { continue }
                return statusCode
            }
        }
        return nil
    }

    private func relatedErrors(startingAt error: NSError) -> [NSError] {
        var errors = [error]
        var current = error
        var remainingDepth = 8
        while remainingDepth > 0,
              let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
            errors.append(underlying)
            current = underlying
            remainingDepth -= 1
        }
        return errors
    }
}
