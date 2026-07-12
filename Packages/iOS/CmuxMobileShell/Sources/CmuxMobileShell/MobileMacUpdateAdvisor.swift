/// A truthful recommendation that a released Mac update unlocks mobile-visible features.
public struct MobileMacUpdateHint: Equatable, Sendable {
    /// The missing features that a released Mac update unlocks, in registry order without duplicates.
    public let features: [MobileMacUpdateFeature]

    /// The minimum Mac marketing version that unlocks every listed feature.
    public let minimumMacVersion: MobileMacAppVersion

    /// The connected Mac's current marketing version.
    public let macAppVersion: MobileMacAppVersion

    /// The stable missing-capability identifiers used to build the dismissal signature.
    private let missingCapabilities: [String]

    /// Creates a Mac update hint from contributing capability requirements.
    ///
    /// - Parameters:
    ///   - features: The unique features to present, in registry order.
    ///   - minimumMacVersion: The minimum Mac version that unlocks the features.
    ///   - macAppVersion: The connected Mac's current version.
    ///   - missingCapabilities: The contributing stable capability identifiers.
    init(
        features: [MobileMacUpdateFeature],
        minimumMacVersion: MobileMacAppVersion,
        macAppVersion: MobileMacAppVersion,
        missingCapabilities: [String]
    ) {
        self.features = features
        self.minimumMacVersion = minimumMacVersion
        self.macAppVersion = macAppVersion
        self.missingCapabilities = missingCapabilities
    }

    /// A stable signature that re-arms dismissal when the capability gap or target version changes.
    public var dismissalSignature: String {
        "\(Set(missingCapabilities).sorted().joined(separator: ","))>=\(minimumMacVersion)"
    }
}

/// Decides whether a connected Mac has a released update that unlocks known mobile features.
// lint:allow namespace-enum, namespace-type — the Part A specification requires this stateless static API shape.
public enum MobileMacUpdateAdvisor {
    /// Builds a truthful update hint for missing capabilities available in a newer released Mac version.
    ///
    /// - Parameters:
    ///   - hostCapabilities: Capabilities from a successfully decoded `mobile.host.status` response.
    ///   - versionString: The connected Mac's reported marketing version.
    ///   - requirements: The capability release registry known to the iOS build.
    /// - Returns: A hint when at least one missing capability shipped after the Mac version, otherwise `nil`.
    public static func hint(
        hostCapabilities: Set<String>,
        macAppVersion versionString: String?,
        requirements: [MobileMacUpdateCapabilityRequirement] = MobileMacUpdateCapabilityRequirement.standard
    ) -> MobileMacUpdateHint? {
        guard let versionString,
              let macAppVersion = MobileMacAppVersion(parsing: versionString)
        else {
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
        let features = contributors.compactMap { requirement in
            seenFeatures.insert(requirement.feature).inserted ? requirement.feature : nil
        }
        return MobileMacUpdateHint(
            features: features,
            minimumMacVersion: minimumMacVersion,
            macAppVersion: macAppVersion,
            missingCapabilities: contributors.map(\.capability)
        )
    }
}
