public import Foundation

/// How a bare typed word that may be an intranet host (`wiki`, `go`) is
/// checked, after Chrome's `IntranetRedirectBehavior` policy, which a
/// company's Chrome profile may set and cmux honors.
///
/// `go/gday`, `wiki/Page` and `devbox:8080` always load (a path or a port
/// makes a single label an address); only a bare word needs a DNS answer.
public nonisolated enum IntranetRedirectBehavior: Int, Sendable, Equatable {
    /// Policy 1: no DNS check; a bare word is a search.
    case disabled = 1
    /// Policy 2: a bare word that resolves loads, with no check for a
    /// resolver that answers every name.
    case withoutInterceptionCheck = 2
    /// Policy 3, and the default: a bare word that resolves loads, unless
    /// the resolver answers random names too (a captive or ISP resolver).
    case withInterceptionCheck = 3

    /// The behavior for a policy value: 1, 2 or 3; anything else is the default.
    public init(policyValue: Int?) {
        self = policyValue.flatMap(Self.init(rawValue:)) ?? .withInterceptionCheck
    }
}
