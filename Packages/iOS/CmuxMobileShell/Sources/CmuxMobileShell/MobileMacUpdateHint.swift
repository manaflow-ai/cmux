/// A truthful recommendation that a released Mac update unlocks mobile-visible features.
public struct MobileMacUpdateHint: Equatable, Sendable {
    /// The missing features that a released Mac update unlocks, in registry order without duplicates.
    public let features: [MobileMacUpdateFeature]

    /// The minimum Mac marketing version that unlocks every listed feature.
    public let minimumMacVersion: MobileMacAppVersion

    /// The connected Mac's current marketing version, explicit or inferred.
    public let macAppVersion: MobileMacAppVersion

    /// Whether ``macAppVersion`` was inferred from the advertised capability set
    /// rather than reported by the Mac. Released Macs older than 0.64.16 predate
    /// the `mac_app_version` status field (and pre-0.64.17 attach tickets carry
    /// no version either), so the versions this registry targets can only be
    /// established by inference. UI copy must not state an inferred version as
    /// the Mac's current version.
    public let isVersionInferred: Bool

    /// The stable missing-capability identifiers used to build the dismissal signature.
    private let missingCapabilities: [String]

    /// Creates a Mac update hint from contributing capability requirements.
    ///
    /// - Parameters:
    ///   - features: The unique features to present, in registry order.
    ///   - minimumMacVersion: The minimum Mac version that unlocks the features.
    ///   - macAppVersion: The connected Mac's current version, explicit or inferred.
    ///   - isVersionInferred: Whether the version was derived from advertised capabilities.
    ///   - missingCapabilities: The contributing stable capability identifiers.
    init(
        features: [MobileMacUpdateFeature],
        minimumMacVersion: MobileMacAppVersion,
        macAppVersion: MobileMacAppVersion,
        isVersionInferred: Bool,
        missingCapabilities: [String]
    ) {
        self.features = features
        self.minimumMacVersion = minimumMacVersion
        self.macAppVersion = macAppVersion
        self.isVersionInferred = isVersionInferred
        self.missingCapabilities = missingCapabilities
    }

    /// A stable signature that re-arms dismissal when the capability gap or target version changes.
    public var dismissalSignature: String {
        "\(Set(missingCapabilities).sorted().joined(separator: ","))>=\(minimumMacVersion)"
    }

    /// Builds a truthful update hint for missing capabilities available in a newer released Mac version.
    ///
    /// The Mac's version comes from `mobile.host.status` or the attach ticket
    /// when present. Both fields postdate the releases the standard registry
    /// targets (status gained `mac_app_version` in 0.64.16, tickets in
    /// 0.64.17), so when neither is available the version is inferred as the
    /// newest `firstReleasedMacVersion` among registry capabilities the host
    /// DOES advertise: a released Mac advertising a capability that first
    /// shipped in X is at least X, and a released Mac at X missing a
    /// capability that shipped in Y > X is older than Y. A host advertising
    /// no registered capability yields no inference and no hint.
    ///
    /// - Parameters:
    ///   - hostCapabilities: Capabilities from a successfully decoded `mobile.host.status` response.
    ///   - versionString: The connected Mac's reported marketing version, when available.
    ///   - requirements: The capability release registry known to the iOS build.
    /// - Returns: A hint when at least one missing capability shipped after the Mac version, otherwise `nil`.
    public init?(
        hostCapabilities: Set<String>,
        macAppVersion versionString: String?,
        requirements: [MobileMacUpdateCapabilityRequirement] = MobileMacUpdateCapabilityRequirement.standard
    ) {
        let explicitVersion = versionString.flatMap { MobileMacAppVersion(parsing: $0) }
        // An unparseable non-empty version (nightly/prerelease marker) stays
        // conservative: it is an explicit report we cannot compare, so no
        // inference and no hint, rather than second-guessing a custom build.
        if let versionString, !versionString.isEmpty, explicitVersion == nil {
            return nil
        }
        let inferredVersion = explicitVersion == nil
            ? requirements
                .filter { requirement in
                    requirement.firstReleasedMacVersion != nil
                        && hostCapabilities.contains(requirement.capability)
                }
                .compactMap(\.firstReleasedMacVersion)
                .max()
            : nil
        guard let macAppVersion = explicitVersion ?? inferredVersion else {
            return nil
        }

        let contributors = requirements.filter { requirement in
            guard let releaseVersion = requirement.firstReleasedMacVersion else { return false }
            return !hostCapabilities.contains(requirement.capability) && macAppVersion < releaseVersion
        }
        guard !contributors.isEmpty,
              let minimumMacVersion = contributors.compactMap(\.firstReleasedMacVersion).max()
        else {
            return nil
        }

        var seenFeatures: Set<MobileMacUpdateFeature> = []
        self.init(
            features: contributors.compactMap { requirement in
                seenFeatures.insert(requirement.feature).inserted ? requirement.feature : nil
            },
            minimumMacVersion: minimumMacVersion,
            macAppVersion: macAppVersion,
            isVersionInferred: explicitVersion == nil,
            missingCapabilities: contributors.map(\.capability)
        )
    }
}
