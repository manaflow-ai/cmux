#if DEBUG
public import Foundation

/// Builds browser-import fixtures from a process-environment dictionary so UI
/// tests can drive the import dialog with deterministic browsers and
/// destination profiles instead of whatever is installed on the test machine.
///
/// Constructed with the environment it reads (`init(environment:)`), then asked
/// for ``browsers`` and ``destinationProfiles``; this replaces the former
/// caseless `BrowserImportUITestFixtureLoader` namespace-enum of `static`
/// functions taking the environment as a parameter.
public struct BrowserImportUITestFixtureLoader {
    /// One browser fixture decoded from the
    /// `CMUX_UI_TEST_BROWSER_IMPORT_FIXTURE` environment value.
    private struct BrowserFixture: Decodable {
        let browserName: String
        let profiles: [String]
    }

    private let environment: [String: String]

    /// Creates a loader that reads its fixtures from `environment`.
    public init(environment: [String: String]) {
        self.environment = environment
    }

    /// Decodes a single installed-browser candidate from
    /// `CMUX_UI_TEST_BROWSER_IMPORT_FIXTURE`, or `nil` when the variable is
    /// absent or malformed.
    public func browsers() -> [InstalledBrowserCandidate]? {
        guard let rawFixture = environment["CMUX_UI_TEST_BROWSER_IMPORT_FIXTURE"],
              let data = rawFixture.data(using: .utf8),
              let fixture = try? JSONDecoder().decode(BrowserFixture.self, from: data) else {
            return nil
        }

        let resolvedProfiles = fixture.profiles.enumerated().map { index, name in
            InstalledBrowserProfile(
                displayName: name,
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("cmux-ui-test-browser-import")
                    .appendingPathComponent(
                        fixture.browserName
                            .lowercased()
                            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                    )
                    .appendingPathComponent("\(index)-\(name)")
                    .standardizedFileURL,
                isDefault: index == 0
            )
        }

        let descriptor = BrowserImportBrowserDescriptor.allBrowserDescriptors.first(where: {
            $0.displayName == fixture.browserName
        }) ?? BrowserImportBrowserDescriptor(
            id: fixture.browserName
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-")),
            displayName: fixture.browserName,
            family: .chromium,
            tier: 0,
            bundleIdentifiers: [],
            appNames: [],
            dataRootRelativePaths: [],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: false
        )

        return [
            InstalledBrowserCandidate(
                descriptor: descriptor,
                resolvedFamily: descriptor.family,
                homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
                appURL: nil,
                dataRootURL: nil,
                profiles: resolvedProfiles,
                detectionSignals: ["ui-test-fixture"],
                detectionScore: Int.max
            )
        ]
    }

    /// Decodes the destination profiles from
    /// `CMUX_UI_TEST_BROWSER_IMPORT_DESTINATIONS`, or `nil` when the variable is
    /// absent, malformed, or empty.
    public func destinationProfiles() -> [BrowserProfileDefinition]? {
        guard let rawDestinations = environment["CMUX_UI_TEST_BROWSER_IMPORT_DESTINATIONS"],
              let data = rawDestinations.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data),
              !names.isEmpty else {
            return nil
        }

        return names.enumerated().map { index, rawName in
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.localizedCaseInsensitiveCompare("Default") == .orderedSame {
                return BrowserProfileDefinition(
                    id: UUID(uuidString: "52B43C05-4A1D-45D3-8FD5-9EF94952E445")!,
                    displayName: "Default",
                    createdAt: .distantPast,
                    isBuiltInDefault: true
                )
            }
            return BrowserProfileDefinition(
                id: UUID(),
                displayName: name.isEmpty ? "Profile \(index + 1)" : name,
                createdAt: .distantPast,
                isBuiltInDefault: false
            )
        }
    }
}
#endif
