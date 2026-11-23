public import Foundation
#if canImport(FoundationNetworking)
public import FoundationNetworking
#endif

/// Which cloud data space a build's requests ask for, decided once in each app's composition root and passed to
/// every client that talks to a cloud backend (cloud-api, cmux-mobile-api).
///
/// A dev build fails closed: with no usable tag it never falls back to nightly's space (no header), because that
/// would read and change the data of the person's own nightly build. Its clients refuse every call instead, with
/// ``CMUXBuildSpaceError``.
public enum CMUXBuildSpaceState: Sendable, Hashable {
    /// Nightly, stable, release, TestFlight, App Store and Demo builds: the default space, no header.
    case nightly
    /// A tagged dev build: `X-Cmux-Build-Space: dev:<slug>` on every request and WebSocket upgrade.
    case dev(CMUXBuildSpace)
    /// A dev build with no usable tag: every cloud call is refused with ``CMUXBuildSpaceError``.
    case misconfiguredDev(reason: String)

    /// The state of a build. `devBuild`: the build is a dev build (it must have a space of its own); `devTag`: the
    /// tag it ships, if any (blank or an unexpanded `$(…)` build setting counts as none).
    ///
    /// A usable tag makes ``dev(_:)``, in any build. With no tag a dev build is ``misconfiguredDev(reason:)`` and
    /// any other build ``nightly``. A tag with no ASCII letter or digit, or one whose slug is longer than
    /// ``CMUXBuildSpace/maxSlugLength``, is ``misconfiguredDev(reason:)``: it was meant to be a space of its own.
    public init(devBuild: Bool, devTag: String?) {
        let raw = devTag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tag = raw.hasPrefix("$(") ? "" : raw
        if tag.isEmpty {
            self = devBuild ? .misconfiguredDev(reason: "it has no tag") : .nightly
        } else if let space = CMUXBuildSpace(devTag: tag) {
            self = .dev(space)
        } else if CMUXBuildSpace.slug(tag) == nil {
            self = .misconfiguredDev(reason: "its tag \"\(tag)\" has no letter or digit")
        } else {
            self = .misconfiguredDev(reason: "its tag is longer than \(CMUXBuildSpace.maxSlugLength) characters")
        }
    }

    /// The dev build's space; nil for nightly and for a misconfigured dev build.
    public var space: CMUXBuildSpace? {
        if case let .dev(space) = self { space } else { nil }
    }

    /// The refusal of a misconfigured dev build; nil when the build may call the cloud.
    public var refusal: CMUXBuildSpaceError? {
        if case let .misconfiguredDev(reason) = self { .misconfiguredDev(reason: reason) } else { nil }
    }

    /// Throws ``CMUXBuildSpaceError`` for a misconfigured dev build; returns for nightly and a tagged dev build.
    public func check() throws {
        if let refusal { throw refusal }
    }

    /// Adds the header to `request` (an HTTP request or a WebSocket upgrade) for a dev build, nothing for nightly;
    /// throws for a misconfigured dev build, so the request is never sent.
    public func apply(to request: inout URLRequest) throws {
        try check()
        space?.apply(to: &request)
    }

    /// The header as a dictionary (empty for nightly); throws for a misconfigured dev build.
    public func headers() throws -> [String: String] {
        try check()
        return space?.headers ?? [:]
    }

    /// The value of `CMUX_BUILD_SPACE` for every process this build launches (cmux-tui `cmux-build-space`): the
    /// space for a dev build, nil (unset) for nightly, and for a misconfigured dev build a value that is not a space
    /// (``unusableChildValue``), which every Rust cloud client refuses. A child never falls back to nightly's data,
    /// also one launched with a filtered environment that keeps only this variable (the Chief owner).
    public var childEnvironmentValue: String? {
        switch self {
        case .nightly: nil
        case let .dev(space): space.headerValue
        case .misconfiguredDev: Self.unusableChildValue
        }
    }

    /// What a misconfigured dev build's children get: not `dev:<slug>`, so they refuse their cloud calls.
    public static let unusableChildValue = "unusable"

    /// The header's value (`dev:<slug>`), nil for nightly; throws for a misconfigured dev build.
    public func headerValue() throws -> String? {
        try check()
        return space?.headerValue
    }
}

/// Why a dev build refuses a cloud call: it has no usable build space tag.
public enum CMUXBuildSpaceError: Error, Sendable, Hashable, LocalizedError {
    case misconfiguredDev(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .misconfiguredDev(reason):
            "This dev build has no usable build space tag (\(reason)), so it makes no cloud calls: without one it "
                + "would read and change nightly's cloud data. Build it with a tag: ./scripts/reload.sh --tag <name> "
                + "(on the fleet: cmux-ci build cmux --ref <sha> --tag <name>)."
        }
    }
}
