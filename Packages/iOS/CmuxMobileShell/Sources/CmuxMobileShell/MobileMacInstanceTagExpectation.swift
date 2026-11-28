/// Route authority expected from the authenticated Mac status handshake.
enum MobileMacInstanceTagExpectation: Equatable, Sendable {
    /// A fresh QR or legacy nil-tag row may adopt any authenticated tag.
    case adopt
    /// A stored connection keeps this tag when an older host omits it, but
    /// rejects a different nonnil tag.
    case preserve(String)
    /// An explicit registry-instance selection must prove this exact tag.
    case require(String)

    /// The tag this expectation pins, when it pins one.
    var expectedTag: String? {
        switch self {
        case .adopt: nil
        case .preserve(let tag), .require(let tag): tag
        }
    }
}
