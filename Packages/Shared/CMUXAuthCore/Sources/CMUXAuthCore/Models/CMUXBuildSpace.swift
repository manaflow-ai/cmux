public import Foundation
#if canImport(FoundationNetworking)
public import FoundationNetworking
#endif

/// The cloud data space a dev build's requests ask for: `X-Cmux-Build-Space: dev:<slug>`.
///
/// A dev build carries its tag in every request and WebSocket upgrade it sends to the cloud
/// backends (cloud-api and cmux-mobile-api), so dev builds never see each other's data or the
/// data of nightly and stable builds. Nightly, stable, release, TestFlight and App Store builds
/// have no build space and send no header at all.
///
/// The composition root of each app decides whether the build has a dev tag and builds this value
/// once (``init(devTag:)``); clients receive it through `init` and only call
/// ``apply(to:)``. This package never reads a bundle or a build flag itself.
public struct CMUXBuildSpace: Sendable, Hashable {
    /// The request header every cloud backend reads.
    public static let headerName = "X-Cmux-Build-Space"
    /// The longest slug the backends accept (`^dev:[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$`).
    public static let maxSlugLength = 64

    /// The sanitized tag: `[a-z0-9-]`, no leading or trailing `-`, at most 64 characters.
    public let slug: String

    /// The build space of a dev build tagged `devTag`, or nil when the build has no usable tag:
    /// no tag, a tag with no ASCII letter or digit, or a slug longer than ``maxSlugLength``
    /// (rejected rather than truncated, so two tags never share one space).
    public init?(devTag: String?) {
        guard let devTag, let slug = Self.slug(devTag), slug.utf8.count <= Self.maxSlugLength else { return nil }
        self.slug = slug
    }

    /// The header's value: `dev:<slug>`.
    public var headerValue: String { "dev:" + slug }

    /// The header as a dictionary, for clients that pass headers as a map.
    public var headers: [String: String] { [Self.headerName: headerValue] }

    /// Adds the header to `request` (an HTTP request or a WebSocket upgrade).
    public func apply(to request: inout URLRequest) {
        request.setValue(headerValue, forHTTPHeaderField: Self.headerName)
    }

    /// The tag as `scripts/lib/mobile-attach.sh`'s `cmux_attach__slug_raw` makes it: ASCII
    /// lowercase, every run of characters outside `[a-z0-9]` becomes one `-`, and leading and
    /// trailing `-` are trimmed. Nil when nothing is left. The length is not checked here.
    public static func slug(_ raw: String) -> String? {
        var slug = ""
        for scalar in raw.unicodeScalars {
            let value = scalar.value
            let lowered: Unicode.Scalar? = switch value {
            case 0x61...0x7A, 0x30...0x39: scalar
            case 0x41...0x5A: Unicode.Scalar(value + 0x20)
            default: nil
            }
            if let lowered {
                slug.unicodeScalars.append(lowered)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? nil : slug
    }
}
