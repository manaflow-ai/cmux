import Foundation

/// A response fixture that models HTTP/2's lowercase header field names.
///
/// Safety: the fixture adds no mutable state to Foundation's response object.
final class LowercaseHeaderHTTPURLResponse:
    HTTPURLResponse,
    @unchecked Sendable
{
    override var allHeaderFields: [AnyHashable: Any] {
        super.allHeaderFields.reduce(into: [:]) { result, entry in
            result[AnyHashable(String(describing: entry.key).lowercased())] = entry.value
        }
    }
}
